import Foundation
import AudioDomain
import CoreAudio

/// Shared plumbing for capture objects: the bounded handoff from the audio thread to a
/// worker that yields into the AsyncStream. The audio thread only locks, copies, and signals;
/// the worker is the single writer to the stream.
///
/// Back-pressure is visible end to end. The stream is `bufferingNewest`, so when the consumer
/// falls behind it evicts the oldest element on every yield. Each eviction is inspected: an
/// evicted packet's interval is folded into a pending gap that is re-yielded ahead of the next
/// packet (an evicted gap is folded back the same way), and evicted control events are
/// replayed. No captured interval can leave the pipeline without either its audio or a gap
/// covering it reaching the consumer, and the dropped duration is counted in `queueStats`.
final class CaptureHandoff: @unchecked Sendable {
    let laneID: String
    private let queue: BoundedAudioQueue
    private let semaphore = DispatchSemaphore(value: 0)
    private let exited = DispatchSemaphore(value: 0)
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    private var sequence: UInt64 = 0
    private var timeline: LaneTimeline
    private(set) var callbackCount: UInt64 = 0
    /// Non-audio events produced on the audio thread (timeline / queue gaps), yielded in order.
    private var pendingControl: [CaptureEvent] = []
    /// Interval evicted from the stream and not yet re-reported.
    private var evicted: (start: Int64, end: Int64, epoch: UInt64)?
    /// Control events evicted from the stream, to be replayed.
    private var replay: [CaptureEvent] = []
    private var streamDroppedNs: Int64 = 0
    private(set) var clockCorrections = 0

    init(laneID: String, sessionAnchorNs: Int64, sampleRate: Double, continuation: AsyncStream<CaptureEvent>.Continuation) {
        self.laneID = laneID
        self.queue = BoundedAudioQueue(capacityNs: 2_000_000_000)
        self.continuation = continuation
        self.timeline = LaneTimeline(sessionAnchorNs: sessionAnchorNs, captureEpoch: 0, sampleRate: sampleRate)
    }

    func beginEpoch(_ epoch: UInt64, sampleRate: Double) {
        lock.withLock {
            timeline.beginEpoch(epoch, sampleRate: sampleRate)
        }
    }

    var epoch: UInt64 { lock.withLock { timeline.captureEpoch } }

    func startWorker() {
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        let t = Thread { [weak self] in
            self?.workerLoop()
        }
        t.name = "LiveLearn.capture.\(laneID)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Stops the worker and waits (bounded) for it to flush what it still holds, so the caller's
    /// subsequent `.stopped` lands after the last packet / gap.
    func stopWorker() {
        let wasRunning: Bool = lock.withLock {
            let r = running
            running = false
            return r
        }
        semaphore.signal()
        if wasRunning {
            _ = exited.wait(timeout: .now() + .milliseconds(300))
        }
    }

    /// Called from the audio thread. `channels` must already be owned copies.
    func deliver(channels: [[Float]], format: AudioFormatDescriptor, hostTime: UInt64?) {
        let frames = channels.first?.count ?? 0
        guard frames > 0 else { return }
        let hostNs = hostTime.map { MonotonicClock.hostTimeToNs($0) }
        let (stamp, epoch, seq): (LaneTimeline.Stamp, UInt64, UInt64) = lock.withLock {
            callbackCount &+= 1
            let s = timeline.stamp(frameCount: frames, hostNs: hostNs)
            if s.clockCorrectedNs > 0 { clockCorrections += 1 }
            sequence &+= 1
            return (s, timeline.captureEpoch, sequence)
        }
        if let g = stamp.gap {
            lock.withLock { pendingControl.append(.gap(AudioGap(laneID: laneID, captureEpoch: epoch, startNs: g.0, endNs: g.1, reason: .captureStall))) }
        }
        let packet = AudioPacket(laneID: laneID, captureEpoch: epoch, sequence: seq, sourceStartNs: stamp.startNs, sourceEndNs: stamp.endNs, format: format, samples: OwnedAudioBuffer(channels: channels), discontinuityBefore: stamp.discontinuityBefore)
        if let gap = queue.push(packet) {
            lock.withLock { pendingControl.append(.gap(gap)) }
        }
        semaphore.signal()
    }

    /// Any event that does not carry audio (started, health, stopped, failed, gaps from the
    /// control queue). Thread-safe; goes through the same eviction accounting as packets.
    func yield(_ event: CaptureEvent) {
        enqueue(event)
    }

    private func workerLoop() {
        defer { exited.signal() }
        while true {
            semaphore.wait()
            let alive = lock.withLock { running }
            drainToStream()
            if !alive {
                if let g = takeEvicted() { yieldRaw(.gap(g)) }
                return
            }
        }
    }

    private func drainToStream() {
        while true {
            let control: [CaptureEvent] = lock.withLock {
                let c = pendingControl
                pendingControl.removeAll(keepingCapacity: true)
                return c
            }
            for e in control { enqueue(e) }
            guard let p = queue.pop() else { break }
            enqueue(.packet(p))
        }
    }

    /// The single choke point onto the AsyncStream.
    private func enqueue(_ event: CaptureEvent) {
        let pendingReplay: [CaptureEvent] = lock.withLock {
            let r = replay
            replay.removeAll()
            return r
        }
        for r in pendingReplay { yieldRaw(r) }
        if let g = takeEvicted() { yieldRaw(.gap(g)) }
        yieldRaw(event)
    }

    private func yieldRaw(_ event: CaptureEvent) {
        if case .dropped(let old) = continuation.yield(event) {
            noteEvicted(old)
        }
    }

    private func noteEvicted(_ e: CaptureEvent) {
        switch e {
        case .packet(let p):
            fold(start: p.sourceStartNs, end: p.sourceEndNs, epoch: p.captureEpoch, countDropped: true)
        case .gap(let g):
            fold(start: g.startNs, end: g.endNs, epoch: g.captureEpoch, countDropped: false)
        case .started, .health, .stopped, .failed:
            lock.withLock { replay.append(e) }
        }
    }

    private func fold(start: Int64, end: Int64, epoch: UInt64, countDropped: Bool) {
        lock.withLock {
            if countDropped { streamDroppedNs += max(0, end - start) }
            if let cur = evicted {
                evicted = (min(cur.start, start), max(cur.end, end), max(cur.epoch, epoch))
            } else {
                evicted = (start, end, epoch)
            }
        }
    }

    private func takeEvicted() -> AudioGap? {
        let e: (start: Int64, end: Int64, epoch: UInt64)? = lock.withLock {
            let v = evicted
            evicted = nil
            return v
        }
        guard let e else { return nil }
        return AudioGap(laneID: laneID, captureEpoch: e.epoch, startNs: e.start, endNs: e.end, reason: .queueOverflow)
    }

    /// Bounded-queue statistics with stream evictions folded into `droppedNs`.
    var queueStats: BoundedAudioQueue.Stats {
        var s = queue.stats
        s.droppedNs += lock.withLock { streamDroppedNs }
        return s
    }
}

// MARK: - PCM layouts

/// How to read samples out of an AudioBufferList. Only layouts listed here are decoded; a device
/// or tap reporting anything else is refused at start instead of being misread.
struct PCMLayout: Sendable {
    let descriptor: AudioFormatDescriptor
    let bytesPerFrame: Int
    let bytesPerSample: Int
    /// Multiplier that maps the raw integer to −1…1 (unused for float layouts).
    let scale: Float

    init?(_ asbd: AudioStreamBasicDescription) {
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return nil }
        let flags = asbd.mFormatFlags
        guard flags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        // Bytes one sample occupies in memory (its container), regardless of valid bits.
        let container = nonInterleaved ? bytesPerFrame : bytesPerFrame / max(channels, 1)
        guard container > 0 else { return nil }
        let type: AudioFormatDescriptor.SampleType
        var scale: Float = 1
        if isFloat {
            switch container {
            case 4: type = .float32
            case 8: type = .float64
            default: return nil
            }
        } else {
            guard flags & kAudioFormatFlagIsSignedInteger != 0 else { return nil }
            switch (bits, container) {
            case (16, 2):
                type = .int16
                scale = 1 / 32768
            case (24, 3):
                type = .int24
                scale = 1 / 8_388_608
            case (32, 4):
                type = .int32
                scale = 1 / 2_147_483_648
            case (24, 4):
                type = .int32
                // 24 valid bits in a 32-bit container: high-aligned reads like Int32, low-aligned needs 2^23.
                scale = flags & kAudioFormatFlagIsAlignedHigh != 0 ? 1 / 2_147_483_648 : 1 / 8_388_608
            default:
                return nil
            }
        }
        self.descriptor = AudioFormatDescriptor(sampleRate: asbd.mSampleRate, channelCount: channels, sampleType: type, isInterleaved: !nonInterleaved)
        self.bytesPerFrame = bytesPerFrame
        self.bytesPerSample = container
        self.scale = scale
    }
}

extension AudioStreamBasicDescription {
    /// The decodable shape of this stream, or nil when the layout is not supported.
    var layout: PCMLayout? { PCMLayout(self) }
}

/// Copies an AudioBufferList into owned de-interleaved Float32 channels.
func copyChannels(from list: UnsafePointer<AudioBufferList>, layout: PCMLayout) -> [[Float]] {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
    let channelCount = layout.descriptor.channelCount
    guard channelCount > 0, buffers.count > 0 else { return [] }
    var out: [[Float]] = []
    if !layout.descriptor.isInterleaved {
        for buf in buffers {
            guard let data = buf.mData else { continue }
            let frames = Int(buf.mDataByteSize) / max(layout.bytesPerSample, 1)
            out.append(decode(data, count: frames, stride: 1, offset: 0, layout: layout))
        }
    } else {
        let buf = buffers[0]
        guard let data = buf.mData else { return [] }
        let frames = Int(buf.mDataByteSize) / max(layout.bytesPerFrame, 1)
        out.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            out.append(decode(data, count: frames, stride: channelCount, offset: c, layout: layout))
        }
    }
    return out
}

/// Reads `count` samples starting at sample `offset`, `stride` samples apart.
private func decode(_ data: UnsafeMutableRawPointer, count: Int, stride: Int, offset: Int, layout: PCMLayout) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    switch layout.descriptor.sampleType {
    case .float32:
        let p = data.assumingMemoryBound(to: Float.self)
        for f in 0..<count { out[f] = p[f * stride + offset] }
    case .float64:
        let p = data.assumingMemoryBound(to: Double.self)
        for f in 0..<count { out[f] = Float(p[f * stride + offset]) }
    case .int16:
        let p = data.assumingMemoryBound(to: Int16.self)
        for f in 0..<count { out[f] = Float(p[f * stride + offset]) * layout.scale }
    case .int32:
        let p = data.assumingMemoryBound(to: Int32.self)
        for f in 0..<count { out[f] = Float(p[f * stride + offset]) * layout.scale }
    case .int24:
        let p = data.assumingMemoryBound(to: UInt8.self)
        for f in 0..<count {
            let i = (f * stride + offset) * 3
            // Little-endian 24-bit two's complement → sign-extended Int32.
            let raw = Int32(p[i]) | (Int32(p[i + 1]) << 8) | (Int32(p[i + 2]) << 16)
            let value = raw & 0x800000 != 0 ? raw - 0x1000000 : raw
            out[f] = Float(value) * layout.scale
        }
    }
    return out
}
