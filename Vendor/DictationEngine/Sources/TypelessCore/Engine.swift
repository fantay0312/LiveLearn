// CoreEngine: encoder + transport + session, confined to one serial queue.
import Foundation

/// Per-stage latency series for `--stats` (spec §25 names + hot-path stages).
public struct EngineStats: Sendable {
    public var captureToEncode = LatencySeries()
    public var encodeToSend = LatencySeries()
    public var encodeDuration = LatencySeries()
    public var interimGap = LatencySeries()
    public var packets = 0
    public init() {}

    public func summary(session: SessionStats) -> JSONValue {
        func opt(_ v: Double?) -> JSONValue { v.map { .double(($0 * 1000).rounded() / 1000) } ?? .null }
        return .obj([
            ("session_id_hash", .string(session.sessionIdHash)),
            ("audio_frame_count", .int(Int64(session.audioFrameCount))),
            ("audio_duration_ms", .int(Int64(session.audioDurationMs))),
            ("bytes_sent", .int(Int64(session.bytesSent))),
            ("bytes_received", .int(Int64(session.bytesReceived))),
            ("responses", .int(Int64(session.responses))),
            ("transcripts", .int(Int64(session.transcripts))),
            ("result_count", .int(Int64(session.resultCount))),
            ("pass_name", .string(session.passName)),
            ("vad_finished", .bool(session.vadFinished)),
            ("remote_status_code", .int(Int64(session.remoteStatusCode))),
            ("session_start_latency_ms", opt(session.sessionStartLatencyMs)),
            ("first_text_latency_ms", opt(session.firstTextLatencyMs)),
            ("final_latency_ms", opt(session.finalLatencyMs)),
            ("capture_to_encode_ms", captureToEncode.summary()),
            ("encode_duration_ms", encodeDuration.summary()),
            ("encode_to_send_ms", encodeToSend.summary()),
            ("interim_gap_ms", interimGap.summary()),
        ])
    }
}

public final class CoreEngine {
    public let profile: ASRProfile
    public let transport: ASRTransport
    public let session: ASRSession
    public let encoder: SpeechOpusEncoder
    public let queue: DispatchQueue
    public private(set) var stats = EngineStats()
    private var packetBuf = [UInt8](repeating: 0, count: speechOpusPacketBytes)
    private var lastTranscriptNs: UInt64 = 0
    private var closed = false

    public init(profile: ASRProfile, transport: ASRTransport, queue: DispatchQueue? = nil,
                clock: @escaping () -> Int64 = wallClockMs, idFactory: () -> String = newTaskId,
                finishMode: FinishMode = .pending, encoder: SpeechOpusEncoder? = nil) throws {
        self.profile = profile
        self.transport = transport
        self.queue = queue ?? DispatchQueue(label: "typeless.engine", qos: .userInteractive)
        self.encoder = try encoder ?? SpeechOpusEncoder()
        self.session = ASRSession(profile: profile, transport: transport, clock: clock, idFactory: idFactory, finishMode: finishMode)
    }

    /// Opens the transport, then drives StartTask → StartSession. `session.onStarted` fires on
    /// SessionStarted; `session.onError` on any failure (including connect failures).
    public func start(sessionPayload: [UInt8]) {
        transport.open { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.session.fail(ASRSessionError("connect failed: \(error)"))
                return
            }
            do { try self.session.start(sessionPayload: sessionPayload) } catch {
                self.session.fail(ASRSessionError("\(error)"))
            }
        }
    }

    /// Encode one 40 ms PCM frame and push it (pending-last-packet policy). `captureNs` is the
    /// monotonic timestamp of the capture completing this frame (mic path) for stage timing.
    public func pushPCM40(_ pcm: UnsafeRawBufferPointer, captureNs: UInt64 = 0) throws {
        let t0 = monotonicNanos()
        if captureNs > 0, t0 >= captureNs { stats.captureToEncode.add(ns: t0 - captureNs) }
        try packetBuf.withUnsafeMutableBytes { try encoder.encode40ms(pcm, into: $0) }
        let t1 = monotonicNanos()
        stats.encodeDuration.add(ns: t1 - t0)
        try packetBuf.withUnsafeBytes { try session.pushPacket($0) }
        stats.encodeToSend.add(ns: monotonicNanos() - t1)
        stats.packets += 1
    }

    public func pushPCM40(_ pcm: [UInt8]) throws { try pcm.withUnsafeBytes { try pushPCM40($0) } }

    /// Push an already-encoded 320-byte packet (mic path encodes on its own thread).
    public func pushPacket(_ packet: UnsafeRawBufferPointer, encodedNs: UInt64 = 0, captureNs: UInt64 = 0) throws {
        let t0 = monotonicNanos()
        if captureNs > 0, encodedNs >= captureNs { stats.captureToEncode.add(ns: encodedNs - captureNs) }
        try session.pushPacket(packet)
        if encodedNs > 0, t0 >= encodedNs { stats.encodeToSend.add(ns: monotonicNanos() - encodedNs) }
        stats.packets += 1
    }

    public func noteTranscript() {
        let now = monotonicNanos()
        if lastTranscriptNs > 0 { stats.interimGap.add(ns: now - lastTranscriptNs) }
        lastTranscriptNs = now
    }

    public func finish() throws { try session.finish() }

    public func close() {
        if closed { return }
        closed = true
        session.close()
    }

    public func statsJSON() -> JSONValue { stats.summary(session: session.snapshotStats()) }
}

public enum TranscribeError: Error, CustomStringConvertible {
    case timeout(String)
    case session(ASRSessionError)
    public var description: String {
        switch self {
        case .timeout(let m): return "timeout: \(m)"
        case .session(let e): return e.message
        }
    }
}

public struct TranscribeResult {
    public var text: String
    public var transcripts: [TranscriptEvent]
    public var events: [WebSocketResponse]
    public var taskId: String
    public var remoteFinished: Bool
    public var stats: JSONValue
}

/// Synchronous whole-buffer transcription (CLI `asr`): start → push packets → finish. Blocks the
/// calling thread on semaphores while the engine queue runs the duplex session.
public func transcribePCM(
    _ pcm: [UInt8], profile: ASRProfile, transport: ASRTransport, twoPass: Bool = true, threePass: Bool = false,
    context: JSONValue? = nil, pad: Bool = true, finishMode: FinishMode = .pending, realtimePacing: Bool = false,
    timeout: TimeInterval = 15, clock: @escaping () -> Int64 = wallClockMs, idFactory: () -> String = newTaskId,
    onTranscript: ((TranscriptEvent) -> Void)? = nil
) throws -> TranscribeResult {
    let engine = try CoreEngine(profile: profile, transport: transport, clock: clock, idFactory: idFactory, finishMode: finishMode)
    defer { engine.queue.sync { engine.close() } }
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var failure: ASRSessionError? = nil
    engine.session.onStarted = { started.signal() }
    engine.session.onFinished = { finished.signal() }
    engine.session.onTranscript = { ev in engine.noteTranscript(); onTranscript?(ev) }
    engine.session.onError = { err in
        lock.lock(); failure = err; lock.unlock()
        started.signal()
        finished.signal()
    }
    let payload = buildStartSessionPayload(
        deviceId: profile.deviceId, appId: profile.appId, twoPass: twoPass, threePass: threePass,
        context: context, inputMode: profile.inputMode, iid: profile.iid, extraOverlay: profile.startSessionExtra)
    engine.queue.async { engine.start(sessionPayload: payload) }
    guard started.wait(timeout: .now() + timeout) == .success else { throw TranscribeError.timeout("SessionStarted") }
    lock.lock(); let f1 = failure; lock.unlock()
    if let f1 = f1 { throw TranscribeError.session(f1) }

    let packets = try engine.encoder.encodePCM(pcm, pad: pad)
    var pushError: Error? = nil
    for packet in packets {
        engine.queue.sync {
            do { try engine.session.pushPacket(packet) } catch { pushError = error }
        }
        if let e = pushError { throw e }
        if realtimePacing { usleep(UInt32(frameMs * 1000)) }
    }
    engine.queue.sync {
        do { try engine.finish() } catch { pushError = error }
    }
    if let e = pushError { throw e }
    guard finished.wait(timeout: .now() + timeout) == .success else { throw TranscribeError.timeout("SessionFinished") }
    lock.lock(); let f2 = failure; lock.unlock()
    if let f2 = f2 { throw TranscribeError.session(f2) }
    return engine.queue.sync {
        TranscribeResult(
            text: engine.session.transcripts.last?.text ?? "",
            transcripts: engine.session.transcripts,
            events: engine.session.events,
            taskId: engine.session.taskId,
            remoteFinished: engine.session.remoteSessionFinished,
            stats: engine.statsJSON())
    }
}
