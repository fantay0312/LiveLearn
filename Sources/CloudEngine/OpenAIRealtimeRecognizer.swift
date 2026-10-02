import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "openai-realtime")

/// OpenAI Realtime API, transcription intent, and servers that speak the same protocol.
///
/// Wire facts this is built on (verified 2026-09 against the API reference and SDK types):
/// `wss://api.openai.com/v1/realtime?intent=transcription`, bearer auth, PCM16 mono at 24 kHz
/// only, `session.update` with `session.type = "transcription"`, server VAD so that
/// `input_audio_buffer.speech_started/stopped` carry `audio_start_ms/audio_end_ms`, deltas and
/// `completed` per `item_id`, 60 minutes per session. OpenAI rejects `?model=` on this intent;
/// compatible servers (speaches…) want it, so both the URL shape and the legacy
/// `transcription_session.update` body are per-endpoint switches.
public struct OpenAIRealtimeConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    /// Put `model=` in the URL and use the flat beta session body (compatible servers).
    public var legacyProtocol: Bool
    public var displayName: String
    public var destination: String
    public var isLocal: Bool
    /// Free text the transcription model is primed with ("Vocabulary: LiveLearn, WhisperKit.").
    public var prompt: String? = nil

    public init(baseURL: URL = URL(string: "wss://api.openai.com/v1/realtime")!, apiKey: String?, model: String = "gpt-4o-transcribe", legacyProtocol: Bool = false, displayName: String = "OpenAI 实时识别", destination: String = "OpenAI（美国）", isLocal: Bool = false) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.legacyProtocol = legacyProtocol
        self.displayName = displayName
        self.destination = destination
        self.isLocal = isLocal
    }
}

public final class OpenAIRealtimeRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 24_000
    public let config: OpenAIRealtimeConfig
    private let state: RealtimeState

    public init(config: OpenAIRealtimeConfig) {
        self.config = config
        self.state = RealtimeState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "openai.realtime", displayName: config.displayName, modelID: config.model, isLocal: config.isLocal, dataDestination: config.isLocal ? "本机服务，不出本机" : "音频发送到 \(config.destination)", costUnit: config.isLocal ? "免费" : "按音频分钟计费")
    }

    public var supportsAutoDetect: Bool { true }
    /// Times come from the server's voice activity detector, padded on both sides.
    public var timingQuality: TimingQuality { .estimated }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if !config.isLocal, (config.apiKey ?? "").isEmpty { return .blocked("\(config.displayName)需要 API Key；请在 设置 › 引擎 › 识别 中填写。") }
        if config.model.isEmpty { return .blocked("\(config.displayName)需要一个模型名称。") }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        try await state.start(request)
    }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async { await state.commit() }
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    public static func url(config: OpenAIRealtimeConfig) -> URL {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        var items = comps.queryItems ?? []
        if !items.contains(where: { $0.name == "intent" }) { items.append(URLQueryItem(name: "intent", value: "transcription")) }
        if config.legacyProtocol, !items.contains(where: { $0.name == "model" }) { items.append(URLQueryItem(name: "model", value: config.model)) }
        comps.queryItems = items
        return comps.url ?? config.baseURL
    }

    public static func sessionUpdate(config: OpenAIRealtimeConfig, language: String?) throws -> String {
        let lang = language.map { LanguageCode.openAI($0) }
        let body: [String: Any]
        if config.legacyProtocol {
            var transcription: [String: Any] = ["model": config.model]
            if let lang { transcription["language"] = lang }
            if let prompt = config.prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
            body = [
                "type": "transcription_session.update",
                "session": [
                    "input_audio_format": "pcm16",
                    "input_audio_transcription": transcription,
                    "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 500],
                ],
            ]
        } else {
            var transcription: [String: Any] = ["model": config.model]
            if let lang { transcription["language"] = lang }
            if let prompt = config.prompt, !prompt.isEmpty { transcription["prompt"] = prompt }
            body = [
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": [
                        "input": [
                            "format": ["type": "audio/pcm", "rate": sampleRate],
                            "transcription": transcription,
                            "turn_detection": ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 500],
                        ],
                    ],
                ],
            ]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func appendEvent(_ pcm: Data) -> String {
        "{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(pcm.base64EncodedString())\"}"
    }
}

/// Pure mapping of server events onto transcript chunks; the socket owner feeds it and keeps
/// the clock. Timing: `audio_start_ms/audio_end_ms` are buffer-relative; the anchor is the
/// session time of the first sample sent.
public struct OpenAIRealtimeParser: Sendable {
    public struct Item: Sendable, Equatable {
        public var text = ""
        public var startMs: Int?
        public var endMs: Int?
    }
    public enum Outcome: Sendable, Equatable {
        case none
        case chunk(TranscriptChunk)
        case sessionReady
        case error(ProviderError)
    }

    private(set) var items: [String: Item] = [:]
    private var order: [String] = []

    public init() {}

    /// `sentMs`: milliseconds of audio sent so far (the buffer's "now"), for open-ended chunks.
    public mutating func apply(_ json: [String: Any], anchorNs: Int64, sentMs: Int) -> Outcome {
        guard let type = json["type"] as? String else { return .none }
        func ns(_ ms: Int) -> Int64 { anchorNs + Int64(ms) * 1_000_000 }
        let itemID = json["item_id"] as? String
        switch type {
        case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated":
            return .sessionReady
        case "input_audio_buffer.speech_started":
            guard let id = itemID else { return .none }
            var item = items[id] ?? Item()
            item.startMs = json["audio_start_ms"] as? Int
            remember(id, item)
            return .none
        case "input_audio_buffer.speech_stopped":
            guard let id = itemID else { return .none }
            var item = items[id] ?? Item()
            item.endMs = json["audio_end_ms"] as? Int
            remember(id, item)
            return .none
        case "conversation.item.input_audio_transcription.delta":
            guard let id = itemID, let delta = json["delta"] as? String else { return .none }
            var item = items[id] ?? Item()
            item.text += delta
            remember(id, item)
            let start = item.startMs ?? max(0, sentMs - 2_000)
            return .chunk(TranscriptChunk(startNs: ns(start), endNs: ns(max(start, item.endMs ?? sentMs)), text: item.text, isFinal: false))
        case "conversation.item.input_audio_transcription.completed":
            guard let id = itemID else { return .none }
            let item = items[id] ?? Item()
            let transcript = (json["transcript"] as? String) ?? item.text
            forget(id)
            let start = item.startMs ?? max(0, sentMs - 2_000)
            let end = max(start, item.endMs ?? sentMs)
            return .chunk(TranscriptChunk(startNs: ns(start), endNs: ns(end), text: transcript, isFinal: true))
        case "conversation.item.input_audio_transcription.failed":
            guard let id = itemID else { return .none }
            let item = items[id] ?? Item()
            forget(id)
            // What was shown stays as an unfinished sentence rather than vanishing.
            guard !item.text.isEmpty else { return .none }
            let start = item.startMs ?? max(0, sentMs - 2_000)
            return .chunk(TranscriptChunk(startNs: ns(start), endNs: ns(max(start, item.endMs ?? sentMs)), text: item.text, isFinal: true))
        case "error":
            let e = json["error"] as? [String: Any]
            let code = e?["code"] as? String ?? ""
            let message = e?["message"] as? String ?? "未知错误"
            let userFixable = ["invalid_api_key", "invalid_model", "insufficient_quota", "missing_required_parameter", "unknown_parameter", "invalid_value"].contains(code) || (e?["type"] as? String) == "invalid_request_error"
            return .error(ProviderError(userFixable ? .userFixable : .retryable, "OpenAI 实时识别：\(message)\(code.isEmpty ? "" : "（\(code)）")"))
        default:
            return .none
        }
    }

    private mutating func remember(_ id: String, _ item: Item) {
        if items[id] == nil { order.append(id) }
        items[id] = item
        // Bound the memory: items the server never completed are dropped after a while.
        while order.count > 32, let old = order.first {
            order.removeFirst()
            items[old] = nil
        }
    }

    private mutating func forget(_ id: String) {
        items[id] = nil
        order.removeAll { $0 == id }
    }
}

/// BCP-47 codes as each vendor wants them.
enum LanguageCode {
    /// OpenAI transcription takes ISO-639-1 ("zh", "en"); script tags are dropped.
    static func openAI(_ code: String) -> String {
        let c = CaptionDomainBridge.canonical(code)
        if c == "yue" { return "yue" }
        return String(c.split(separator: "-").first ?? Substring(c))
    }

    /// Deepgram: regional tags where it distinguishes scripts, `multi` for auto-detect.
    static func deepgram(_ code: String?) -> String {
        guard let code else { return "multi" }
        switch CaptionDomainBridge.canonical(code) {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "yue": return "zh-HK"
        case "nb": return "no"
        case let other: return other
        }
    }
}

// MARK: - Socket session

actor RealtimeState {
    private let config: OpenAIRealtimeConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var parser = OpenAIRealtimeParser()
    private var anchorNs: Int64?
    private var sentSamples: Int = 0
    private var closed = true
    private var ready = false
    private var readyContinuation: CheckedContinuation<Void, Error>?

    init(config: OpenAIRealtimeConfig) { self.config = config }

    private var sentMs: Int { sentSamples * 1000 / OpenAIRealtimeRecognizer.sampleRate }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        var req = URLRequest(url: OpenAIRealtimeRecognizer.url(config: config))
        if let key = config.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let socket = WebSocketConnection(request: req)
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "\(config.displayName)：\(error.message)")
        }
        self.socket = socket
        closed = false
        ready = false
        parser = OpenAIRealtimeParser()
        anchorNs = nil
        sentSamples = 0
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        do {
            try await socket.send(.text(OpenAIRealtimeRecognizer.sessionUpdate(config: config, language: request.sourceLanguage)))
            // Wait (bounded) for the server to accept the configuration; an `error` here is the
            // classic wrong-model / wrong-key answer and must fail the open, not the first packet.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in try await self?.awaitReady() }
                group.addTask { try await Task.sleep(nanoseconds: 8_000_000_000); throw ProviderError(.retryable, "等待服务器确认会话超时") }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Whatever failed, nothing stays open: socket, receive loop, the ready waiter.
            await teardown()
            if let p = error as? ProviderError { throw ProviderError(p.classification, "\(config.displayName)：\(p.message)") }
            throw ProviderError(.retryable, "\(config.displayName)：发送会话配置失败（\(error.localizedDescription)）")
        }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await self?.ping()
            }
        }
        log.notice("realtime open lane=\(request.laneID, privacy: .public) model=\(self.config.model, privacy: .public) lang=\(request.sourceLanguage ?? "auto", privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(OpenAIRealtimeRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func awaitReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyContinuation = c
        }
    }

    private func ping() { socket?.ping() }

    private func receiveLoop(_ socket: WebSocketConnection) async {
        while !Task.isCancelled, let message = await socket.receive() {
            guard case .text(let text) = message, let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(json)
        }
        socketEnded(socket)
    }

    private func handle(_ json: [String: Any]) {
        guard !closed else { return }
        let outcome = parser.apply(json, anchorNs: anchorNs ?? 0, sentMs: sentMs)
        switch outcome {
        case .none: break
        case .sessionReady:
            ready = true
            readyContinuation?.resume()
            readyContinuation = nil
        case .chunk(let chunk):
            events?.yield(.chunk(chunk))
        case .error(let error):
            if let c = readyContinuation {
                readyContinuation = nil
                c.resume(throwing: error)
            } else {
                events?.yield(.failed(error))
            }
        }
    }

    private func socketEnded(_ socket: WebSocketConnection) {
        guard !closed else { return }
        let why: String
        switch socket.closeInfo {
        case .code(let code, let reason): why = "连接已关闭（\(code)）\(reason.isEmpty ? "" : "：\(reason)")"
        case .error(let e): why = "连接中断：\(e)"
        case nil: why = "连接已关闭"
        }
        let error = ProviderError(.retryable, "\(config.displayName)：\(why)")
        if let c = readyContinuation {
            readyContinuation = nil
            c.resume(throwing: error)
        } else {
            events?.yield(.failed(error))
        }
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        sentSamples += packet.mono.count
        let pcm = PCM16.data(from: packet.mono)
        do {
            try await socket.send(.text(OpenAIRealtimeRecognizer.appendEvent(pcm)))
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "\(config.displayName)：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    /// Ask the server to close the open turn now (pause, end of input).
    func commit() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text("{\"type\":\"input_audio_buffer.commit\"}"))
    }

    func finish() async {
        guard !closed else { return }
        await commit()
        // Give trailing `completed` events a moment to land, then close.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await teardown()
    }

    func cancel() async { await teardown() }

    private func teardown() async {
        closed = true
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        readyContinuation?.resume(throwing: ProviderError(.retryable, "已取消"))
        readyContinuation = nil
        events?.finish()
        events = nil
    }
}
