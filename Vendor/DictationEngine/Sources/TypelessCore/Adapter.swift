// Loopback Adapter session logic (ENGINE_API + spec §18 extras). Pure logic: the WS server in
// TypelessNet feeds frames in and forwards emitted JSON events out. Fully duplex: transcript
// events are emitted the moment the remote delivers them, never waiting for the next PCM push.
import Foundation

public let maxStartJSON = 1024 * 1024
public let maxPCMBuffer = 1024 * 1024
public let finalTimeout: TimeInterval = 15

public let unimplementedRoutes: Set<String> = [
    "/settings", "/context", "/context/wait", "/convert", "/local_convert", "/associate", "/rectify",
    "/hotwords", "/modify_pair", "/candidate/selected", "/candidate/usage",
]

public struct AdapterError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var code: String
    public var retryable: Bool
    public init(_ message: String, code: String = "asr_failed", retryable: Bool = false) {
        self.message = message
        self.code = code
        self.retryable = retryable
    }
    public var description: String { message }
}

public func healthPayload() -> JSONValue {
    .obj([
        ("ok", .bool(true)),
        ("api_version", .string("1")),
        ("capabilities", .array([.string("asr"), .string("interim"), .string("correction")])),
    ])
}

public func errorFrame(_ message: String, code: String = "asr_failed", retryable: Bool = false) -> JSONValue {
    .obj([
        ("type", .string("error")),
        ("error", .string(message)),
        ("message", .string(message)),
        ("code", .string(code)),
        ("retryable", .bool(retryable)),
    ])
}

public func httpErrorBody(code: String, message: String, retryable: Bool = false) -> [UInt8] {
    JSONValue.obj([
        ("ok", .bool(false)),
        ("error", .obj([
            ("code", .string(code)),
            ("message", .string(message)),
            ("retryable", .bool(retryable)),
            ("details", .obj([])),
        ])),
    ]).compactJSONBytes()
}

public func httpReason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 413: return "Payload Too Large"
    case 501: return "Not Implemented"
    case 500: return "Internal Server Error"
    default: return "Error"
    }
}

private func pyBool(_ v: JSONValue?, _ def: Bool) -> Bool { v?.boolValue ?? def }

/// Validates the first `start` frame and fills defaults (spec §18.2).
public func parseStartFrame(_ value: JSONValue) throws -> JSONObject {
    guard let obj = value.objectValue else { throw AdapterError("start frame must be a JSON object", code: "invalid_request") }
    guard obj["type"] == .string("start") else { throw AdapterError("first frame type must be start", code: "invalid_request") }
    var app = ""
    if let a = obj["app"], a.pythonTruthy {
        guard let s = a.stringValue else { throw AdapterError("app must be a string", code: "invalid_request") }
        app = s
    }
    var context = ""
    if let c = obj["context"], c.pythonTruthy {
        guard let s = c.stringValue else { throw AdapterError("context must be a string", code: "invalid_request") }
        context = s
    }
    var cursor = Int64(context.unicodeScalars.count)
    if let c = obj["cursor_position"] {
        guard let i = c.intValue else { throw AdapterError("cursor_position must be an integer", code: "invalid_request") }
        cursor = i
    }
    var window = Int64(defaultWindowChars)
    if let w = obj["context_window_chars"]?.intValue, w > 0 { window = w }
    let hotwords: JSONValue = (obj["hotwords"]?.pythonTruthy ?? false) ? obj["hotwords"]! : .array([])
    let replacements: JSONValue = (obj["replacements"]?.pythonTruthy ?? false) ? obj["replacements"]! : .array([])
    return JSONObject([
        ("type", .string("start")),
        ("app", .string(app)),
        ("context", .string(context)),
        ("cursor_position", .int(cursor)),
        ("context_window_chars", .int(window)),
        ("hotwords", hotwords),
        ("replacements", replacements),
        ("two_pass", .bool(pyBool(obj["two_pass"], true))),
        ("three_pass", .bool(pyBool(obj["three_pass"], false))),
    ])
}

public func readyEvent(document: TypelessDocument, sessionId: String = "", mode: String = "mock") -> JSONValue {
    let fmt = audioFormat().objectValue!
    return .obj([
        ("type", .string("ready")),
        ("api_version", .string("1")),
        ("session_id", .string(sessionId)),
        ("mode", .string(mode)),
        ("typeless", .obj([
            ("context_window_chars", .int(Int64(document.contextWindowChars))),
            ("replacement_rules", document.replacementRulesJSON()),
        ])),
        ("audio", .obj([
            ("format", .string("pcm_s16le")),
            ("sample_rate", fmt["sampleRate"]!),
            ("channels", fmt["channels"]!),
            ("frame_ms", .int(40)),
            ("encoding", fmt["encoding"]!),
            ("frame_samples", fmt["frameSamples"]!),
            ("frame_bytes", fmt["frameBytes"]!),
            ("opus_bitrate", fmt["opusBitrate"]!),
        ])),
    ])
}

public func transcriptToAdapterEvent(_ event: TranscriptEvent, document: TypelessDocument) throws -> JSONValue {
    let raw = event.text
    let corrected = try document.replace(raw)
    let name = passName(event.resultCount)
    let typ = (name == "one" && !event.isFinal) ? "interim" : "correction"
    var body = JSONObject([
        ("type", .string(typ)),
        ("pass", .string(name)),
        ("text", .string(corrected)),
        ("raw_text", .string(raw)),
        ("replacement_applied", .bool(corrected != raw)),
        ("document_preview", .string(try document.preview(raw))),
        ("seq_id", .int(event.seqId)),
        ("start_time", .double(event.startTime)),
        ("end_time", .double(event.endTime)),
        ("segment_final", .bool(event.isFinal)),
        ("candidate_groups", .array(candidateGroups(event.raw))),
    ])
    body.update(adapterCometixFields(event))
    body["display"] = .string(corrected)
    return .object(body)
}

public func buildFinalEvent(document: TypelessDocument, timeline: TranscriptTimeline, seqId: Int64 = 0) throws -> JSONValue {
    let raw = timeline.text
    let corrected = try document.commit(raw)
    let window = document.window()
    let latest = timeline.latestEvent
    var event = JSONObject([
        ("type", .string("final")),
        ("text", .string(corrected)),
        ("raw_text", .string(raw)),
        ("replacement_applied", .bool(corrected != raw)),
        ("document", .string(document.text)),
        ("next_context", .string(window.text)),
        ("next_cursor_position", .int(Int64(window.cursor))),
        ("replacement_rules", document.replacementRulesJSON()),
        ("seq_id", .int(seqId != 0 ? seqId : (latest?.seqId ?? 0))),
        ("start_time", .double(latest?.startTime ?? 0)),
        ("end_time", .double(latest?.endTime ?? 0)),
        ("candidate_groups", .array(candidateGroups(latest?.raw))),
        ("asr_finished", .bool(true)),
    ])
    if let latest = latest {
        event.update(adapterCometixFields(latest, sessionFinal: true))
        event["display"] = .string(corrected)
        event["stable_text"] = .string(corrected)
    }
    return .object(event)
}

/// One `/asr` WebSocket session. Must be driven from a single serial queue (the engine's).
public final class AdapterConnection {
    public let profile: ASRProfile
    public let mode: String
    private let engineFactory: () throws -> CoreEngine
    /// Outbound JSON events (ready/interim/correction/final/error), in order.
    public var emit: (JSONValue) -> Void
    /// Fired once after the terminal event (final or error) has been emitted.
    public var onTerminal: (() -> Void)?

    public private(set) var document: TypelessDocument?
    public private(set) var engine: CoreEngine?
    public private(set) var timeline = TranscriptTimeline()
    public private(set) var gate = SessionFinalGate()
    public private(set) var started = false
    public private(set) var ready = false
    public private(set) var emittedFinal = false
    public private(set) var emittedError = false
    public private(set) var pcmFramesSent = 0
    public private(set) var startOptions = JSONObject()
    public private(set) var finishRequested = false
    private var framer = PCMFramer()
    private var bufferedBytes = 0
    private var closed = false

    public init(profile: ASRProfile = ASRProfile(), mode: String = "mock", engineFactory: @escaping () throws -> CoreEngine,
                emit: @escaping (JSONValue) -> Void = { _ in }) {
        self.profile = profile
        self.mode = mode
        self.engineFactory = engineFactory
        self.emit = emit
    }

    /// Convenience for tests / the mock: an inline MockTransport engine on the given queue.
    public convenience init(profile: ASRProfile = ASRProfile(), queue: DispatchQueue? = nil,
                            emit: @escaping (JSONValue) -> Void = { _ in }) {
        self.init(profile: profile, mode: "mock", engineFactory: {
            try CoreEngine(profile: profile, transport: MockTransport(), queue: queue)
        }, emit: emit)
    }

    private func requireEngine() throws -> CoreEngine {
        guard let engine = engine else { throw AdapterError("engine not started") }
        return engine
    }

    public var terminalSent: Bool { emittedFinal || emittedError }

    // MARK: inbound

    public func onStart(_ value: JSONValue) throws {
        if started { throw AdapterError("duplicate start frame", code: "invalid_request") }
        let start = try parseStartFrame(value)
        startOptions = start
        let document: TypelessDocument
        do { document = try TypelessDocument.fromStart(start) } catch let e as TypelessError {
            throw AdapterError(e.description, code: "invalid_request")
        }
        self.document = document
        let clientHotwords: [Hotword]
        do { clientHotwords = try parseHotwords(start["hotwords"]) } catch let e as TypelessError {
            throw AdapterError(e.description, code: "invalid_request")
        }
        let hotwords = mergeHotwords(clientHotwords, document.hotwordsFromReplacements())
        let window = document.window()
        let app = start["app"]?.stringValue ?? ""
        let context = buildChatContext(text: window.text, cursor: window.cursor, hostId: app.isEmpty ? "EDITOR" : app, hotwords: hotwords)
        let payload = buildStartSessionPayload(
            deviceId: profile.deviceId, appId: profile.appId,
            twoPass: start["two_pass"]?.boolValue ?? true, threePass: start["three_pass"]?.boolValue ?? false,
            context: context, inputMode: profile.inputMode, iid: profile.iid, extraOverlay: profile.startSessionExtra)
        let engine = try engineFactory()
        self.engine = engine
        engine.session.retainHistory = false
        engine.session.onStarted = { [weak self] in self?.handleSessionStarted() }
        engine.session.onTranscript = { [weak self] event in self?.handleTranscript(event) }
        engine.session.onFinished = { [weak self] in self?.handleRemoteFinished() }
        engine.session.onError = { [weak self] error in self?.handleFailure(error.message) }
        started = true
        engine.start(sessionPayload: payload)
    }

    public func onPCM(_ data: UnsafeRawBufferPointer) throws {
        guard started, document != nil else { throw AdapterError("pcm before start", code: "invalid_request") }
        if gate.localFinishReceived { throw AdapterError("pcm after finish", code: "invalid_request") }
        if framer.pendingBytes + data.count > maxPCMBuffer { throw AdapterError("pcm buffer exceeds 1 MiB", code: "invalid_request") }
        do { try framer.append(data) } catch let e as AudioError {
            throw AdapterError(e.description, code: "invalid_request")
        }
        if ready { try drainFrames(finish: false) }
    }

    public func onPCM(_ data: [UInt8]) throws { try data.withUnsafeBytes { try onPCM($0) } }

    public func onFinish() throws {
        guard started, document != nil else { throw AdapterError("finish before start", code: "invalid_request") }
        if terminalSent || finishRequested { return }
        gate.markLocalFinish()
        finishRequested = true
        if ready { try completeFinish() }
        // else: SessionStarted has not arrived yet; `handleSessionStarted` completes the finish.
    }

    public func close() {
        if closed { return }
        closed = true
        engine?.close()
        engine = nil
    }

    // MARK: engine callbacks (same queue)

    private func drainFrames(finish: Bool) throws {
        let engine = try requireEngine()
        try framer.drain(finish: finish) { frame in
            try engine.pushPCM40(frame)
            pcmFramesSent += 1
        }
    }

    private func completeFinish() throws {
        try drainFrames(finish: true)
        try requireEngine().finish()
        if gate.canEmit() { try emitFinal() }
    }

    private func handleSessionStarted() {
        guard let document = document, let engine = engine else { return }
        ready = true
        emit(readyEvent(document: document, sessionId: engine.session.taskId, mode: mode))
        do {
            if finishRequested {
                try completeFinish()
            } else {
                try drainFrames(finish: false)
            }
        } catch {
            handleFailure("\(error)")
        }
    }

    private func handleTranscript(_ event: TranscriptEvent) {
        engine?.noteTranscript()
        timeline.update(event)
        guard !gate.localFinishReceived, let document = document, !terminalSent else { return }
        do { emit(try transcriptToAdapterEvent(event, document: document)) } catch { handleFailure("\(error)") }
    }

    private func handleRemoteFinished() {
        gate.markRemoteFinished()
        if gate.canEmit() {
            do { try emitFinal() } catch { handleFailure("\(error)") }
        }
    }

    private func emitFinal() throws {
        guard gate.canEmit() else { throw AdapterError("session final gate closed") }
        guard let document = document else { throw AdapterError("missing document") }
        let event = try buildFinalEvent(document: document, timeline: timeline, seqId: timeline.latestEvent?.seqId ?? 0)
        gate.markSent()
        emittedFinal = true
        emit(event)
        onTerminal?()
    }

    /// Emits a single error frame (ENGINE_API `error` + spec `message`) unless a terminal
    /// event was already sent, then signals termination.
    public func handleFailure(_ message: String, code: String = "asr_failed", retryable: Bool = false) {
        if terminalSent { return }
        emittedError = true
        emit(errorFrame(message, code: code, retryable: retryable))
        onTerminal?()
    }

    public func handleFailure(_ error: AdapterError) {
        handleFailure(error.message, code: error.code, retryable: error.retryable)
    }
}
