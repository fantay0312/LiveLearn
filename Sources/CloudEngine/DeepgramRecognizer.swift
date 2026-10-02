import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "deepgram")

/// Deepgram streaming (`wss://api.deepgram.com/v1/listen`).
///
/// Wire facts (verified 2026-09 against the AsyncAPI reference): `Authorization: Token`,
/// query-string configuration, binary PCM16 frames, text control frames `KeepAlive` (every
/// 3–5 s of silence, or the socket dies at 10 s), `Finalize`, `CloseStream`; `Results` with
/// `is_final` (settled, never resent) and `speech_final` (endpoint), `UtteranceEnd` from word
/// timings for noisy rooms, timestamps in seconds from the socket's start (a reconnect starts
/// at zero again). `language=multi` on nova-3 covers ten languages and not Chinese or Korean,
/// so auto-detect is only offered as `multi` and the sheet says so.
public struct DeepgramConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    /// Terms to bias towards: `keyterm` on nova-3, `keywords` on older models.
    public var keyterms: [String] = []

    public init(baseURL: URL = URL(string: "wss://api.deepgram.com/v1/listen")!, apiKey: String?, model: String = "nova-3") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

public final class DeepgramRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let config: DeepgramConfig
    private let state: DeepgramState

    public init(config: DeepgramConfig) {
        self.config = config
        self.state = DeepgramState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "deepgram", displayName: "Deepgram 实时识别", modelID: config.model, isLocal: false, dataDestination: "音频发送到 Deepgram（美国）", costUnit: "按音频分钟计费")
    }

    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .segment }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("Deepgram 需要 API Key；请在 设置 › 引擎 › 识别 中填写。") }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream { try await state.start(request) }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async { await state.finalize() }
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    public static func url(config: DeepgramConfig, language: String?) -> URL {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "\(sampleRate)"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "language", value: LanguageCode.deepgram(language)),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "vad_events", value: "true"),
        ]
        for term in config.keyterms where !term.isEmpty {
            items.append(URLQueryItem(name: config.model.hasPrefix("nova-3") ? "keyterm" : "keywords", value: term))
        }
        items.append(contentsOf: comps.queryItems ?? [])
        comps.queryItems = items
        return comps.url ?? config.baseURL
    }
}

/// Pure mapping of Deepgram messages onto transcript chunks. Settled (`is_final`) results
/// accumulate; an interim result replaces the unsettled tail; `speech_final` or an
/// `UtteranceEnd` closes the sentence. Times are seconds since the socket opened; the anchor
/// is the session time of the first sample sent on this socket.
public struct DeepgramParser: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case chunk(TranscriptChunk)
    }

    private struct Piece: Sendable {
        var text: String
        var start: Double
        var end: Double
    }

    private var settled: [Piece] = []
    private var interim: Piece?

    public init() {}

    public var hasOpenSentence: Bool { !settled.isEmpty || interim != nil }

    public mutating func apply(_ json: [String: Any], anchorNs: Int64) -> Outcome {
        guard let type = json["type"] as? String else { return .none }
        func ns(_ s: Double) -> Int64 { anchorNs + Int64((s * 1_000_000_000).rounded()) }
        switch type {
        case "Results":
            guard let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let first = alternatives.first else { return .none }
            let transcript = (first["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let words = first["words"] as? [[String: Any]] ?? []
            let msgStart = json["start"] as? Double ?? 0
            let msgDuration = json["duration"] as? Double ?? 0
            let start = (words.first?["start"] as? Double) ?? msgStart
            let end = (words.last?["end"] as? Double) ?? (msgStart + msgDuration)
            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false
            if !isFinal {
                interim = transcript.isEmpty ? nil : Piece(text: transcript, start: start, end: end)
                guard hasOpenSentence else { return .none }
                return .chunk(current(ns: ns, isFinal: false))
            }
            interim = nil
            if !transcript.isEmpty { settled.append(Piece(text: transcript, start: start, end: end)) }
            guard hasOpenSentence else { return .none }
            if speechFinal {
                let chunk = current(ns: ns, isFinal: true)
                settled = []
                return .chunk(chunk)
            }
            return .chunk(current(ns: ns, isFinal: false))
        case "UtteranceEnd":
            guard hasOpenSentence else { return .none }
            var chunk = current(ns: ns, isFinal: true)
            if let last = json["last_word_end"] as? Double, last >= 0 { chunk.endNs = max(chunk.startNs, ns(last)) }
            settled = []
            interim = nil
            return .chunk(chunk)
        default:
            return .none
        }
    }

    private func current(ns: (Double) -> Int64, isFinal: Bool) -> TranscriptChunk {
        let pieces = settled + (interim.map { [$0] } ?? [])
        let text = Self.join(pieces.map(\.text))
        let start = pieces.first?.start ?? 0
        let end = pieces.last?.end ?? start
        return TranscriptChunk(startNs: ns(start), endNs: max(ns(start), ns(end)), text: text, isFinal: isFinal)
    }

    /// Latin pieces need a space between them; CJK pieces do not.
    static func join(_ parts: [String]) -> String {
        var out = ""
        for p in parts where !p.isEmpty {
            if let last = out.last, let first = p.first, !last.isWhitespace, !(last.isCJK || first.isCJK) {
                out += " "
            }
            out += p
        }
        return out
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

// MARK: - Socket session

actor DeepgramState {
    private let config: DeepgramConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var parser = DeepgramParser()
    private var anchorNs: Int64?
    private var lastSendNs: Int64 = 0
    private var closed = true
    private var closeAcknowledged = false

    init(config: DeepgramConfig) { self.config = config }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        var req = URLRequest(url: DeepgramRecognizer.url(config: config, language: request.sourceLanguage))
        req.setValue("Token \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let socket = WebSocketConnection(request: req)
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "Deepgram：\(error.message)")
        }
        self.socket = socket
        closed = false
        closeAcknowledged = false
        parser = DeepgramParser()
        anchorNs = nil
        lastSendNs = MonotonicClock.nowNs()
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.keepAliveIfIdle()
            }
        }
        log.notice("deepgram open lane=\(request.laneID, privacy: .public) model=\(self.config.model, privacy: .public) lang=\(LanguageCode.deepgram(request.sourceLanguage), privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(DeepgramRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func keepAliveIfIdle() async {
        guard !closed, let socket else { return }
        if MonotonicClock.nowNs() - lastSendNs > 3_000_000_000 {
            try? await socket.send(.text("{\"type\":\"KeepAlive\"}"))
            lastSendNs = MonotonicClock.nowNs()
        }
    }

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
        if json["type"] as? String == "Metadata", closeAcknowledged { return }
        if case .chunk(let chunk) = parser.apply(json, anchorNs: anchorNs ?? 0) {
            events?.yield(.chunk(chunk))
        }
    }

    private func socketEnded(_ socket: WebSocketConnection) {
        guard !closed else { return }
        let why: String
        var classification: ProviderErrorClass = .retryable
        switch socket.closeInfo {
        case .code(let code, let reason):
            why = "连接已关闭（\(code)）\(reason.isEmpty ? "" : "：\(reason)")"
            if reason.contains("DATA-0000") { classification = .unsupported }
        case .error(let e):
            why = "连接中断：\(e)"
            if let status = socket.handshakeStatus, status == 401 || status == 403 { classification = .userFixable }
        case nil:
            why = "连接已关闭"
        }
        events?.yield(.failed(ProviderError(classification, "Deepgram：\(why)")))
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        let pcm = PCM16.data(from: packet.mono)
        // An empty binary frame closes the socket on Deepgram's side.
        guard !pcm.isEmpty else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        do {
            try await socket.send(.data(pcm))
            lastSendNs = MonotonicClock.nowNs()
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "Deepgram：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    /// Pause: flush what is buffered without closing.
    func finalize() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text("{\"type\":\"Finalize\"}"))
        lastSendNs = MonotonicClock.nowNs()
    }

    func finish() async {
        guard !closed, let socket else { return }
        closeAcknowledged = true
        try? await socket.send(.text("{\"type\":\"CloseStream\"}"))
        // Trailing Results arrive before the server's Metadata and close.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await teardown()
    }

    func cancel() async { await teardown() }

    private func teardown() async {
        closed = true
        keepAliveTask?.cancel()
        keepAliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        events?.finish()
        events = nil
    }
}
