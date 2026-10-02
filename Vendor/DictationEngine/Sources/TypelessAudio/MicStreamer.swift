// Dedicated encode thread: waits on the capture semaphore, pulls 20 ms (320 samples at 16 kHz)
// as soon as they exist, resamples, encodes each half immediately, and hands the finished
// 40 ms speech_opus packet to the engine queue. Runs with a Mach time-constraint policy
// (period 20 ms) when the kernel grants it, else QoS user-interactive.
import Darwin
import Foundation
import Synchronization
import TypelessCore

public struct MicStreamerStats: Sendable {
    public var packets = 0
    public var halves = 0
    public var overruns = 0
    public var callbacks = 0
    public var renderErrors = 0
    public var realtimePolicy = false
    public var bufferFrames: UInt32 = 0
    public var deviceRate: Double = 0
    public var captureToPacket = LatencySeries()
}

public final class MicStreamer {
    public let capture: MicCapture
    public let encoder: SpeechOpusEncoder
    private let resampler: Resampler
    /// (packet bytes, captureNs of the newest sample in the packet, encodedNs). Called on the
    /// encode thread; the receiver must copy or dispatch.
    public let onPacket: (UnsafeRawBufferPointer, UInt64, UInt64) -> Void
    private var thread: pthread_t? = nil
    private let running = Atomic<Bool>(false)
    private let pcm20: UnsafeMutablePointer<Int16>
    private var pcm20Filled = 0
    private let packet: UnsafeMutablePointer<UInt8>
    private let statsLock = NSLock()
    private var stats = MicStreamerStats()

    public init(capture: MicCapture, encoder: SpeechOpusEncoder, onPacket: @escaping (UnsafeRawBufferPointer, UInt64, UInt64) -> Void) throws {
        self.capture = capture
        self.encoder = encoder
        self.onPacket = onPacket
        resampler = try Resampler(inputRate: capture.sampleRate > 0 ? capture.sampleRate : capture.device.nominalSampleRate)
        pcm20 = .allocate(capacity: opusFrameSamples)
        pcm20.initialize(repeating: 0, count: opusFrameSamples)
        packet = .allocate(capacity: speechOpusPacketBytes)
        packet.initialize(repeating: 0, count: speechOpusPacketBytes)
    }

    deinit {
        pcm20.deallocate()
        packet.deallocate()
    }

    public func snapshot() -> MicStreamerStats {
        statsLock.lock(); defer { statsLock.unlock() }
        var s = stats
        s.overruns = capture.ring.overruns.load(ordering: .relaxed)
        s.callbacks = capture.callbacks.load(ordering: .relaxed)
        s.renderErrors = capture.renderErrors.load(ordering: .relaxed)
        s.bufferFrames = capture.bufferFrames
        s.deviceRate = capture.sampleRate
        return s
    }

    public func start() {
        if running.exchange(true, ordering: .acquiringAndReleasing) { return }
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0)
        var t: pthread_t? = nil
        let ctx = Unmanaged.passRetained(self).toOpaque()
        pthread_create(&t, &attr, { ctx in
            let streamer = Unmanaged<MicStreamer>.fromOpaque(ctx).takeRetainedValue()
            streamer.threadMain()
            return nil
        }, ctx)
        pthread_attr_destroy(&attr)
        thread = t
    }

    /// Stops the thread and flushes: returns true if a lone 20 ms half was pending (the caller
    /// decides whether to zero-pad it into a final packet).
    public func stop() {
        if !running.exchange(false, ordering: .acquiringAndReleasing) { return }
        semaphore_signal(capture.signal)
        if let t = thread { pthread_join(t, nil) }
        thread = nil
    }

    /// If a 20 ms half is pending after stop, pad with silence into a final packet.
    public func flushPending() -> Bool {
        guard encoder.hasPendingHalfFrame else { return false }
        pcm20.update(repeating: 0, count: opusFrameSamples)
        let done = (try? encoder.pushHalf(UnsafeRawBufferPointer(start: pcm20, count: opusFrameBytes),
                                          into: UnsafeMutableRawBufferPointer(start: packet, count: speechOpusPacketBytes))) ?? false
        if done {
            let now = monotonicNanos()
            onPacket(UnsafeRawBufferPointer(start: packet, count: speechOpusPacketBytes), now, now)
        }
        return done
    }

    private func applyRealtimePolicy() -> Bool {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        func absTime(ms: Double) -> UInt32 {
            UInt32(ms * 1_000_000 * Double(timebase.denom) / Double(timebase.numer))
        }
        var policy = thread_time_constraint_policy_data_t(
            period: absTime(ms: 20), computation: absTime(ms: 2), constraint: absTime(ms: 10), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &policy) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), raw, count)
            }
        }
        return result == KERN_SUCCESS
    }

    private func threadMain() {
        let rt = applyRealtimePolicy()
        statsLock.lock(); stats.realtimePolicy = rt; statsLock.unlock()
        let need = resampler.inputFramesNeeded(for: opusFrameSamples - pcm20Filled)
        var wait = mach_timespec_t(tv_sec: 0, tv_nsec: 100_000_000)
        while running.load(ordering: .acquiring) {
            if capture.ring.available < need {
                _ = semaphore_timedwait(capture.signal, wait)
                wait.tv_nsec = 100_000_000
                continue
            }
            produce()
        }
        // Drain whatever is left in the ring without blocking.
        while capture.ring.available >= resampler.inputFramesNeeded(for: opusFrameSamples) { produce() }
    }

    @inline(__always)
    private func produce() {
        let ring = capture.ring
        let want = opusFrameSamples - pcm20Filled
        let got = resampler.convert(into: pcm20 + pcm20Filled, frames: want) { dst, max in ring.read(into: dst, count: max) }
        if got <= 0 { return }
        pcm20Filled += got
        if pcm20Filled < opusFrameSamples { return }
        pcm20Filled = 0
        let captureNs = capture.lastCaptureNs.load(ordering: .acquiring)
        let done: Bool
        do {
            done = try encoder.pushHalf(UnsafeRawBufferPointer(start: pcm20, count: opusFrameBytes),
                                        into: UnsafeMutableRawBufferPointer(start: packet, count: speechOpusPacketBytes))
        } catch {
            return
        }
        let encodedNs = monotonicNanos()
        statsLock.lock()
        stats.halves += 1
        if done {
            stats.packets += 1
            if encodedNs >= captureNs { stats.captureToPacket.add(ns: encodedNs - captureNs) }
        }
        statsLock.unlock()
        if done { onPacket(UnsafeRawBufferPointer(start: packet, count: speechOpusPacketBytes), captureNs, encodedNs) }
    }
}
