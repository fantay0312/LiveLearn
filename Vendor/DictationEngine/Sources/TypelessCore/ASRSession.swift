// ASR event state machine, seq_id, pending last-packet finish_audio (spec §11, §13, §15).
//
// Unlike the Python version (blocking send + recv on one thread), this state machine is fully
// event-driven: sends never wait for responses, and every incoming frame is handled the moment
// the transport delivers it, so interim results reach the Adapter client live.
import Foundation

public let successStatus: Set<UInt64> = [0, 20000000]
public let passthroughEvents: Set<String> = ["", "ASRResponse", "TaskResult", "Pong"]

public struct ASRSessionError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum ASRSessionState: String, Sendable {
    case connected = "CONNECTED"
    case waitTaskStarted = "WAIT_TASK_STARTED"
    case waitSessionStarted = "WAIT_SESSION_STARTED"
    case streaming = "STREAMING"
    case finishing = "FINISHING"
    case closed = "CLOSED"
    case failed = "FAILED"
}

public func newTaskId() -> String { UUID().uuidString.uppercased() }

/// Transport contract. All callbacks must be delivered on the queue that owns the session
/// (the engine's serial queue); `send` must never block on the remote.
public protocol ASRTransport: AnyObject {
    var onMessage: (([UInt8]) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var bytesSent: Int { get }
    var bytesReceived: Int { get }
    func open(completion: @escaping (Error?) -> Void)
    func send(_ data: [UInt8]) throws
    func close()
}

/// `TaskFrame` metadata bytes: `{"timestamp_ms":N}` / `{"timestamp_ms":N,"extra":{"finish_audio":true}}`.
@inline(__always)
public func taskFrameMetadata(timestampMs: Int64, finishAudio: Bool) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(64)
    out.append(contentsOf: "{\"timestamp_ms\":".utf8)
    out.append(contentsOf: String(timestampMs).utf8)
    if finishAudio { out.append(contentsOf: ",\"extra\":{\"finish_audio\":true}".utf8) }
    out.append(UInt8(ascii: "}"))
    return out
}

public struct TaskFrame: Equatable, Sendable {
    public var seqId: UInt64
    public var data: [UInt8]
    public var finishAudio: Bool
    public var timestampMs: Int64 = 0
    public func metadata() -> [UInt8] { taskFrameMetadata(timestampMs: timestampMs, finishAudio: finishAudio) }
}

/// Spec §15.1: always hold the most recent complete packet so the last real packet carries
/// finish_audio. Storage is a fixed 320-byte buffer; no allocation per push.
public struct PendingPacketBuffer {
    private var storage = [UInt8](repeating: 0, count: speechOpusPacketBytes)
    private var storedCount = 0
    public private(set) var hasPending = false
    public private(set) var seqId: UInt64 = 0

    public init() {}

    public var pending: [UInt8]? { hasPending ? Array(storage[0..<storedCount]) : nil }

    /// Returns the frame to send now (the previously pending packet), if any.
    public mutating func push(_ packet: [UInt8]) -> TaskFrame? {
        var outgoing: TaskFrame? = nil
        if hasPending { outgoing = take(Array(storage[0..<storedCount]), finishAudio: false) }
        store(packet)
        return outgoing
    }

    /// Zero-copy variant: `body` receives the outgoing packet bytes (valid during the call).
    public mutating func push(_ packet: UnsafeRawBufferPointer, body: (UInt64, UnsafeRawBufferPointer) throws -> Void) rethrows {
        if hasPending {
            seqId += 1
            let seq = seqId
            try storage.withUnsafeBytes { try body(seq, UnsafeRawBufferPointer(rebasing: $0[0..<storedCount])) }
        }
        store(packet)
    }

    public mutating func finish() -> TaskFrame {
        let packet = hasPending ? Array(storage[0..<storedCount]) : []
        hasPending = false
        storedCount = 0
        return take(packet, finishAudio: true)
    }

    private mutating func store(_ packet: [UInt8]) {
        precondition(packet.count <= storage.count)
        storage.withUnsafeMutableBytes { $0.copyBytes(from: packet) }
        storedCount = packet.count
        hasPending = true
    }

    private mutating func store(_ packet: UnsafeRawBufferPointer) {
        precondition(packet.count <= storage.count)
        storage.withUnsafeMutableBytes { $0.copyMemory(from: packet) }
        storedCount = packet.count
        hasPending = true
    }

    private mutating func take(_ packet: [UInt8], finishAudio: Bool) -> TaskFrame {
        seqId += 1
        return TaskFrame(seqId: seqId, data: packet, finishAudio: finishAudio)
    }

    mutating func nextSeq() -> UInt64 { seqId += 1; return seqId }
}

public func isSuccess(_ response: WebSocketResponse) -> Bool { successStatus.contains(response.statusCode) }

/// Text `ping`/`pong` map to a protocol Pong (spec §10.3).
public func parseResponseEvent(_ raw: [UInt8]) throws -> WebSocketResponse {
    if raw.count == 4 {
        if raw == Array("pong".utf8) || raw == Array("ping".utf8) { return WebSocketResponse(event: "Pong") }
    }
    return try WebSocketResponse.decode(raw)
}

public func finishAudioFlag(_ request: WebSocketRequest) -> Bool {
    guard !request.payload.isEmpty, let obj = try? JSONParser.parse(request.payload) else { return false }
    return obj["extra"]?["finish_audio"] == .bool(true)
}

public func lastTaskRequest(_ events: [WebSocketRequest]) -> WebSocketRequest? {
    events.last { $0.event == "TaskRequest" }
}

/// Per-session timing/counters in spec §25 vocabulary.
public struct SessionStats: Sendable {
    public var sessionIdHash = ""
    public var audioFrameCount = 0
    public var audioDurationMs: Int { audioFrameCount * frameMs }
    public var bytesSent = 0
    public var bytesReceived = 0
    public var resultCount = 0
    public var passName = "one"
    public var vadFinished = false
    public var remoteStatusCode: UInt64 = 0
    public var startNs: UInt64 = 0
    public var sessionStartedNs: UInt64 = 0
    public var firstTaskSendNs: UInt64 = 0
    public var firstTextNs: UInt64 = 0
    public var finishNs: UInt64 = 0
    public var finishedNs: UInt64 = 0
    public var responses = 0
    public var transcripts = 0

    public var firstTextLatencyMs: Double? {
        guard firstTextNs > 0, firstTaskSendNs > 0 else { return nil }
        return Double(firstTextNs - firstTaskSendNs) / 1e6
    }
    public var finalLatencyMs: Double? {
        guard finishedNs > 0, finishNs > 0 else { return nil }
        return Double(finishedNs - finishNs) / 1e6
    }
    public var sessionStartLatencyMs: Double? {
        guard sessionStartedNs > 0, startNs > 0 else { return nil }
        return Double(sessionStartedNs - startNs) / 1e6
    }
}

public final class ASRSession {
    public let profile: ASRProfile
    public let transport: ASRTransport
    public let clock: () -> Int64
    public let taskId: String
    public let finishMode: FinishMode
    public private(set) var state: ASRSessionState = .connected
    public private(set) var events: [WebSocketResponse] = []
    public private(set) var transcripts: [TranscriptEvent] = []
    public private(set) var remoteSessionFinished = false
    public private(set) var pending = PendingPacketBuffer()
    public private(set) var stats = SessionStats()
    public private(set) var lastError: ASRSessionError? = nil

    /// Keep decoded responses/transcripts in memory (CLI/tests). Adapter sets false to bound memory.
    public var retainHistory = true

    public var onStarted: (() -> Void)?
    public var onResponse: ((WebSocketResponse) -> Void)?
    public var onTranscript: ((TranscriptEvent) -> Void)?
    public var onFinished: (() -> Void)?
    public var onError: ((ASRSessionError) -> Void)?

    private var writer = ProtoWriter(capacity: 1024)
    private var sessionPayload: [UInt8] = []

    public init(profile: ASRProfile, transport: ASRTransport, clock: @escaping () -> Int64 = wallClockMs,
                idFactory: () -> String = newTaskId, finishMode: FinishMode = .pending) {
        self.profile = profile
        self.transport = transport
        self.clock = clock
        self.taskId = idFactory()
        self.finishMode = finishMode
        stats.sessionIdHash = sha12(taskId)
        transport.onMessage = { [weak self] raw in self?.handleIncoming(raw) }
        transport.onFailure = { [weak self] err in self?.fail(ASRSessionError("transport failure: \(err)")) }
    }

    // MARK: sending

    private func send(event: String, payload: [UInt8] = [], data: UnsafeRawBufferPointer? = nil,
                      seqId: UInt64 = 0, includeAppkey: Bool = true) throws {
        writer.reset()
        if !profile.token.isEmpty { writer.writeStringField(1, profile.token) }
        if includeAppkey, !profile.appKey.isEmpty { writer.writeStringField(2, profile.appKey) }
        writer.writeStringField(3, profile.namespace.isEmpty ? "ASR" : profile.namespace)
        writer.writeStringField(5, event)
        if !payload.isEmpty { writer.writeBytesField(6, payload) }
        if let data = data, data.count > 0 { writer.writeBytesField(7, data) }
        writer.writeStringField(8, taskId)
        if seqId != 0 { writer.writeVarintField(9, seqId) }
        stats.bytesSent += writer.bytes.count
        try transport.send(writer.bytes)
    }

    private func sendTaskFrame(seqId: UInt64, data: UnsafeRawBufferPointer?, finishAudio: Bool) throws {
        let meta = taskFrameMetadata(timestampMs: clock(), finishAudio: finishAudio)
        if stats.firstTaskSendNs == 0 { stats.firstTaskSendNs = monotonicNanos() }
        if let d = data, d.count > 0 { stats.audioFrameCount += 1 }
        try send(event: "TaskRequest", payload: meta, data: data, seqId: seqId, includeAppkey: false)
    }

    public func start(sessionPayload payload: [UInt8]) throws {
        guard state == .connected else { throw ASRSessionError("start in state \(state.rawValue)") }
        sessionPayload = payload
        state = .waitTaskStarted
        stats.startNs = monotonicNanos()
        try send(event: "StartTask")
    }

    public func pushPacket(_ packet: [UInt8]) throws {
        try packet.withUnsafeBytes { try pushPacket($0) }
    }

    public func pushPacket(_ packet: UnsafeRawBufferPointer) throws {
        guard state == .streaming else { throw ASRSessionError("audio push before SessionStarted") }
        switch finishMode {
        case .pending:
            try pending.push(packet) { seq, bytes in try sendTaskFrame(seqId: seq, data: bytes, finishAudio: false) }
        case .eager:
            try sendTaskFrame(seqId: pending.nextSeq(), data: packet, finishAudio: false)
        }
    }

    public func finish() throws {
        guard state == .streaming || state == .connected else { throw ASRSessionError("finish in state \(state.rawValue)") }
        stats.finishNs = monotonicNanos()
        let frame = pending.finish()
        try frame.data.withUnsafeBytes { try sendTaskFrame(seqId: frame.seqId, data: $0, finishAudio: true) }
        state = .finishing
        try send(event: "FinishSession")
        // With an inline transport (mock), SessionFinished may already have arrived above.
    }

    public func close() {
        transport.close()
        if state != .closed && state != .failed { state = .closed }
    }

    // MARK: receiving

    public func handleIncoming(_ raw: [UInt8]) {
        if state == .closed || state == .failed { return }
        stats.bytesReceived += raw.count
        let response: WebSocketResponse
        do { response = try parseResponseEvent(raw) } catch {
            fail(ASRSessionError("bad response envelope: \(error)"))
            return
        }
        stats.responses += 1
        if retainHistory { events.append(response) }
        onResponse?(response)
        if response.event == "TaskFailed" || response.event == "SessionFailed" {
            let text = response.statusText.trimmingCharacters(in: .whitespaces)
            let extra = text.isEmpty ? "" : " text=\(text)"
            stats.remoteStatusCode = response.statusCode
            fail(ASRSessionError("remote failed event=\(response.event) status=\(response.statusCode)\(extra)"))
            return
        }
        let finishedEvent = response.event == "SessionFinished"
        do {
            if let event = try normalizePayload(response.payload, envelopeSeq: Int64(response.seqId), streamFinished: finishedEvent) {
                stats.transcripts += 1
                stats.resultCount = event.resultCount
                stats.passName = passName(event.resultCount)
                stats.vadFinished = event.vadFinished
                if stats.firstTextNs == 0 && !event.text.isEmpty { stats.firstTextNs = monotonicNanos() }
                if retainHistory { transcripts.append(event) }
                onTranscript?(event)
            }
        } catch {
            fail(ASRSessionError("bad ASR payload: \(error)"))
            return
        }
        if finishedEvent { remoteSessionFinished = true }

        switch state {
        case .waitTaskStarted:
            if response.event == "TaskStarted" {
                guard isSuccess(response) else {
                    fail(ASRSessionError("expected ['TaskStarted'] got failure TaskStarted status=\(response.statusCode)")); return
                }
                state = .waitSessionStarted
                do { try send(event: "StartSession", payload: sessionPayload) } catch { fail(ASRSessionError("send failed: \(error)")) }
            } else if !passthroughEvents.contains(response.event) {
                fail(ASRSessionError("unexpected event \(response.event.isEmpty ? "<empty>" : response.event) while waiting for ['TaskStarted']"))
            }
        case .waitSessionStarted:
            if response.event == "SessionStarted" {
                guard isSuccess(response) else {
                    fail(ASRSessionError("expected ['SessionStarted'] got failure SessionStarted status=\(response.statusCode)")); return
                }
                state = .streaming
                stats.sessionStartedNs = monotonicNanos()
                onStarted?()
            } else if !passthroughEvents.contains(response.event) {
                fail(ASRSessionError("unexpected event \(response.event.isEmpty ? "<empty>" : response.event) while waiting for ['SessionStarted']"))
            }
        case .streaming:
            // Mirrors `_drain_available`: only TaskFailed/SessionFailed abort mid-stream.
            break
        case .finishing:
            if finishedEvent {
                guard isSuccess(response) else {
                    fail(ASRSessionError("expected ['SessionFinished'] got failure SessionFinished status=\(response.statusCode)")); return
                }
                state = .closed
                stats.finishedNs = monotonicNanos()
                onFinished?()
            } else if !passthroughEvents.contains(response.event) {
                fail(ASRSessionError("unexpected event \(response.event.isEmpty ? "<empty>" : response.event) while waiting for ['SessionFinished']"))
            }
        case .connected, .closed, .failed:
            break
        }
    }

    public func fail(_ error: ASRSessionError) {
        guard state != .failed && state != .closed else { return }
        state = .failed
        lastError = error
        onError?(error)
    }

    /// Fold transport-level byte counters into the stats snapshot.
    public func snapshotStats() -> SessionStats {
        var s = stats
        s.bytesSent = max(s.bytesSent, transport.bytesSent)
        s.bytesReceived = max(s.bytesReceived, transport.bytesReceived)
        return s
    }
}
