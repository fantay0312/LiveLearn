import Testing
import Foundation
import CoreAudio
import AudioDomain
@testable import MacAudio

@Suite("Capture handoff back-pressure")
struct CaptureHandoffTests {
    /// B13: a consumer that reads late must see every lost interval as a gap, and the dropped
    /// duration must be counted. Mirrors QA10 with the capture layer's real buffering policy.
    @Test("Stream overflow is reported as gaps covering the evicted audio")
    func overflowProducesGaps() async throws {
        let pair = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let handoff = CaptureHandoff(laneID: "l", sessionAnchorNs: MonotonicClock.nowNs(), sampleRate: 48_000, continuation: pair.continuation)
        handoff.beginEpoch(1, sampleRate: 48_000)
        handoff.startWorker()
        let format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        // 1000 × 10 ms packets = 10 s of audio, delivered with explicit host times.
        let base = MonotonicClock.hostTimeNow()
        for i in 0..<1000 {
            handoff.deliver(channels: [[Float](repeating: 0.1, count: 480)], format: format, hostTime: base + UInt64(i) * 240_000)
        }
        try await Task.sleep(for: .milliseconds(200))
        handoff.stopWorker()
        pair.continuation.finish()
        var packets = 0
        var packetNs: Int64 = 0
        var gapNs: Int64 = 0
        var gaps = 0
        var lastEnd: Int64 = -1
        var ordered = true
        for await event in pair.stream {
            switch event {
            case .packet(let p):
                packets += 1
                packetNs += p.durationNs
                if p.sourceStartNs < lastEnd { ordered = false }
                lastEnd = max(lastEnd, p.sourceEndNs)
            case .gap(let g):
                gaps += 1
                gapNs += g.durationNs
                lastEnd = max(lastEnd, g.endNs)
            default: break
            }
        }
        #expect(packets < 1000, "the 256-element buffer cannot hold everything; the test needs real eviction")
        #expect(gaps > 0)
        #expect(ordered)
        // Packets plus gaps must cover every delivered nanosecond, within one packet of slack
        // for the interval merged at the very end.
        #expect(packetNs + gapNs >= 1000 * 10_000_000 - 10_000_000, "covered \(packetNs + gapNs) ns")
        #expect(handoff.queueStats.droppedNs > 0)
        #expect(handoff.queueStats.droppedNs == 10_000_000 * Int64(1000 - packets))
    }

    @Test("Without overflow every packet arrives and nothing is counted as dropped")
    func noOverflow() async throws {
        let pair = AsyncStream<CaptureEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let handoff = CaptureHandoff(laneID: "l", sessionAnchorNs: MonotonicClock.nowNs(), sampleRate: 48_000, continuation: pair.continuation)
        handoff.beginEpoch(1, sampleRate: 48_000)
        handoff.startWorker()
        let format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        for _ in 0..<100 {
            handoff.deliver(channels: [[Float](repeating: 0.1, count: 480)], format: format, hostTime: nil)
        }
        try await Task.sleep(for: .milliseconds(50))
        handoff.stopWorker()
        pair.continuation.finish()
        var packets = 0
        var gaps = 0
        for await event in pair.stream {
            switch event {
            case .packet: packets += 1
            case .gap: gaps += 1
            default: break
            }
        }
        #expect(packets == 100)
        #expect(gaps == 0)
        #expect(handoff.queueStats.droppedNs == 0)
    }
}

@Suite("PCM layouts")
struct PCMLayoutTests {
    private func asbd(rate: Double = 48_000, channels: UInt32 = 2, bits: UInt32, flags: AudioFormatFlags, bytesPerSample: UInt32) -> AudioStreamBasicDescription {
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bytesPerFrame = nonInterleaved ? bytesPerSample : bytesPerSample * channels
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
    }

    @Test("Float32, Int16, Int24 and Int32 decode to the same normalized values; others are refused")
    func decodeLayouts() {
        // Interleaved stereo, two frames: L=+0.5, R=-0.5 then L=0, R=+0.25.
        func check(_ layout: PCMLayout?, bytes: [UInt8], file: String) {
            guard let layout else { Issue.record("layout nil for \(file)"); return }
            var data = bytes
            let channels: [[Float]] = data.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return withUnsafePointer(to: &list) { copyChannels(from: $0, layout: layout) }
            }
            #expect(channels.count == 2, "\(file)")
            #expect(channels[0].count == 2, "\(file)")
            #expect(abs(channels[0][0] - 0.5) < 0.001, "\(file) L0 \(channels[0][0])")
            #expect(abs(channels[1][0] + 0.5) < 0.001, "\(file) R0 \(channels[1][0])")
            #expect(abs(channels[0][1]) < 0.001, "\(file)")
            #expect(abs(channels[1][1] - 0.25) < 0.001, "\(file) R1 \(channels[1][1])")
        }
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

        let floatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let floats: [Float] = [0.5, -0.5, 0, 0.25]
        check(asbd(bits: 32, flags: floatFlags, bytesPerSample: 4).layout, bytes: floats.flatMap { withUnsafeBytes(of: $0) { Array($0) } }, file: "float32")

        let intFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        let i16: [Int16] = [16384, -16384, 0, 8192]
        check(asbd(bits: 16, flags: intFlags, bytesPerSample: 2).layout, bytes: i16.flatMap(le), file: "int16")

        let i32: [Int32] = [1 << 30, -(1 << 30), 0, 1 << 29]
        check(asbd(bits: 32, flags: intFlags, bytesPerSample: 4).layout, bytes: i32.flatMap(le), file: "int32")

        let i24: [Int32] = [1 << 22, -(1 << 22), 0, 1 << 21]
        let packed24 = i24.flatMap { v -> [UInt8] in let b = le(v); return [b[0], b[1], b[2]] }
        check(asbd(bits: 24, flags: intFlags, bytesPerSample: 3).layout, bytes: packed24, file: "int24")

        // 24 valid bits, low-aligned in a 32-bit container.
        check(asbd(bits: 24, flags: kAudioFormatFlagIsSignedInteger, bytesPerSample: 4).layout, bytes: i24.flatMap(le), file: "int24in32")

        #expect(asbd(bits: 8, flags: intFlags, bytesPerSample: 1).layout == nil)
        #expect(asbd(bits: 16, flags: kAudioFormatFlagIsPacked, bytesPerSample: 2).layout == nil, "unsigned integer is refused")
        #expect(asbd(bits: 16, flags: intFlags | kAudioFormatFlagIsBigEndian, bytesPerSample: 2).layout == nil)
        var notPCM = asbd(bits: 16, flags: intFlags, bytesPerSample: 2)
        notPCM.mFormatID = kAudioFormatMPEG4AAC
        #expect(notPCM.layout == nil)
    }

    @Test("Non-interleaved buffers are read per channel")
    func nonInterleaved() {
        let layout = asbd(channels: 2, bits: 32, flags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved, bytesPerSample: 4).layout
        #expect(layout?.descriptor.isInterleaved == false)
        var left: [Float] = [0.1, 0.2, 0.3]
        var right: [Float] = [-0.1, -0.2, -0.3]
        let out: [[Float]] = left.withUnsafeMutableBytes { l in
            right.withUnsafeMutableBytes { r in
                // AudioBufferList with two buffers needs manual layout.
                let listPtr = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(listPtr.unsafeMutablePointer) }
                listPtr[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
                listPtr[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
                return copyChannels(from: UnsafePointer(listPtr.unsafeMutablePointer), layout: layout!)
            }
        }
        #expect(out.count == 2)
        #expect(out[0] == [0.1, 0.2, 0.3])
        #expect(out[1] == [-0.1, -0.2, -0.3])
    }
}
