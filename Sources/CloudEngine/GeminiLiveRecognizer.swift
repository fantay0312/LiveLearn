import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "gemini-live")

/// Gemini Live API in transcription mode (`gemini-3.5-transcribe-live`): audio in, text out.
///
/// Wire facts (ai.google.dev Live API reference and live-transcribe guide, 2026-09, plus two
/// open-source macOS clients): `wss://generativelanguage.googleapis.com/ws/google.ai.
/// generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=…`, a `setup` message
/// with `inputAudioTranscription` at the root (nesting it under `generationConfig` closes the
/// socket with 1007), `mode: "SMART"` and empty `languageCodes` so the model detects the
/// language, `customVocabulary` for terms, audio as base64 PCM16 at 16 kHz in `realtimeInput`,
/// `interimInputTranscription` / `inputTranscription` in `serverContent`, `goAway` before the
/// 10-minute cap. No timestamps: times are estimated from the audio sent so far.
public struct GeminiLiveConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var vocabulary: [String]

    public init(baseURL: URL = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!, apiKey: String?, model: String = "gemini-3.5-transcribe-live", vocabulary: [String] = []) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.vocabulary = vocabulary
    }
}

public final class GeminiLiveRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let config: GeminiLiveConfig
    private let state: GeminiLiveState

    public init(config: GeminiLiveConfig) {
        self.config = config
        self.state = GeminiLiveState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "gemini.live", displayName: "Gemini 实时识别", modelID: config.model, isLocal: false, dataDestination: "音频发送到 Google Gemini（美国）", costUnit: "按音频 token 计费")
    }

    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .estimated }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("Gemini 实时识别需要 API Key；请在 设置 › 引擎 中填写（与 Gemini 翻译共用）。") }
        if config.model.isEmpty { return .blocked("Gemini 实时识别需要一个模型名称。") }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream { try await state.start(request) }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async {}
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    /// The key travels in the query string, as Google's own SDK sends it; the URL is never logged.
    public static func url(config: GeminiLiveConfig) -> URL {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "key", value: config.apiKey ?? "")]
        return comps.url ?? config.baseURL
    }

    public static func setup(config: GeminiLiveConfig) throws -> String {
        var transcription: [String: Any] = ["languageCodes": [String](), "mode": "SMART"]
        if !config.vocabulary.isEmpty { transcription["customVocabulary"] = config.vocabulary }
        let body: [String: Any] = [
            "setup": [
                "model": "models/\(config.model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": transcription,
                "realtimeInputConfig": ["automaticActivityDetection": ["disabled": false, "silenceDurationMs": 500, "prefixPaddingMs": 300]],
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func audioMessage(_ pcm: Data) -> String {
        "{\"realtimeInput\":{\"audio\":{\"data\":\"\(pcm.base64EncodedString())\",\"mimeType\":\"audio/pcm;rate=\(sampleRate)\"}}}"
    }

    public static let audioStreamEnd = "{\"realtimeInput\":{\"audioStreamEnd\":true}}"
}

/// `interimInputTranscription` is the sentence in progress, `inputTranscription` a finished one.
/// Times: the sentence starts where the previous one ended and ends at the audio sent so far.
public struct GeminiLiveParser: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case ready
        case chunk(TranscriptChunk)
        case goAway
    }

    private var sentenceStartMs = 0

    public init() {}

    public mutating func apply(_ json: [String: Any], anchorNs: Int64, sentMs: Int) -> Outcome {
        func ns(_ ms: Int) -> Int64 { anchorNs + Int64(ms) * 1_000_000 }
        if json["setupComplete"] != nil { return .ready }
        if json["goAway"] != nil { return .goAway }
        guard let content = json["serverContent"] as? [String: Any] else { return .none }
        if let t = content["inputTranscription"] as? [String: Any], let text = (t["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let start = min(sentenceStartMs, sentMs)
            let chunk = TranscriptChunk(startNs: ns(start), endNs: ns(max(start, sentMs)), text: text, isFinal: true)
            sentenceStartMs = sentMs
            return .chunk(chunk)
        }
        if let t = content["interimInputTranscription"] as? [String: Any], let text = (t["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let start = min(sentenceStartMs, sentMs)
            return .chunk(TranscriptChunk(startNs: ns(start), endNs: ns(max(start, sentMs)), text: text, isFinal: false))
        }
        return .none
    }
}

// MARK: - Socket session

actor GeminiLiveState {
    private let config: GeminiLiveConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var parser = GeminiLiveParser()
    private var anchorNs: Int64?
    private var sentSamples = 0
    private var closed = true
    private var readyContinuation: CheckedContinuation<Void, Error>?

    private var sentMs: Int { sentSamples * 1000 / GeminiLiveRecognizer.sampleRate }

    init(config: GeminiLiveConfig) { self.config = config }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        let socket = WebSocketConnection(request: URLRequest(url: GeminiLiveRecognizer.url(config: config)))
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "Gemini：\(error.message)")
        }
        self.socket = socket
        closed = false
        parser = GeminiLiveParser()
        anchorNs = nil
        sentSamples = 0
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        do {
            try await socket.send(.text(try GeminiLiveRecognizer.setup(config: config)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in try await self?.awaitReady() }
                group.addTask { try await Task.sleep(nanoseconds: 8_000_000_000); throw ProviderError(.retryable, "等待 setupComplete 超时") }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await teardown()
            if let p = error as? ProviderError { throw ProviderError(p.classification, "Gemini：\(p.message)") }
            throw ProviderError(.retryable, "Gemini：发送 setup 失败（\(error.localizedDescription)）")
        }
        log.notice("gemini live open lane=\(request.laneID, privacy: .public) model=\(self.config.model, privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(GeminiLiveRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyContinuation = c }
    }

    private func receiveLoop(_ socket: WebSocketConnection) async {
        while !Task.isCancelled, let message = await socket.receive() {
            let data: Data
            switch message {
            case .text(let s): data = Data(s.utf8)
            case .data(let d): data = d
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            handle(json)
        }
        socketEnded(socket)
    }

    private func handle(_ json: [String: Any]) {
        guard !closed else { return }
        switch parser.apply(json, anchorNs: anchorNs ?? 0, sentMs: sentMs) {
        case .none: break
        case .ready:
            if let c = readyContinuation { readyContinuation = nil; c.resume() }
        case .chunk(let chunk):
            events?.yield(.chunk(chunk))
        case .goAway:
            // The session is about to end (10-minute cap); the lane reopens with a fresh one.
            events?.yield(.failed(ProviderError(.retryable, "Gemini：会话到期，正在重新连接")))
        }
    }

    private func socketEnded(_ socket: WebSocketConnection) {
        guard !closed else { return }
        let why: String
        var classification: ProviderErrorClass = .retryable
        switch socket.closeInfo {
        case .code(let code, let reason):
            why = "连接已关闭（\(code)）\(reason.isEmpty ? "" : "：\(reason)")"
            if code == 1007 || code == 1008 { classification = .userFixable }
        case .error(let e):
            why = "连接中断：\(e)"
            if let status = socket.handshakeStatus, status == 400 || status == 401 || status == 403 { classification = .userFixable }
        case nil:
            why = "连接已关闭"
        }
        let error = ProviderError(classification, "Gemini：\(why)")
        if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: error) } else { events?.yield(.failed(error)) }
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        let pcm = PCM16.data(from: packet.mono)
        guard !pcm.isEmpty else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        do {
            try await socket.send(.text(GeminiLiveRecognizer.audioMessage(pcm)))
            sentSamples += packet.mono.count
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "Gemini：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    func finish() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text(GeminiLiveRecognizer.audioStreamEnd))
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await teardown()
    }

    func cancel() async { await teardown() }

    private func teardown() async {
        closed = true
        if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: ProviderError(.retryable, "会话已取消")) }
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        events?.finish()
        events = nil
    }
}
