import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "soniox")

/// Soniox real-time speech-to-text (`stt-rt-v5`).
///
/// Wire facts (docs.soniox WebSocket API reference, 2026-09): `wss://stt-rt.soniox.com/
/// transcribe-websocket`, a first JSON frame with `api_key`, `model`, `audio_format`
/// (`pcm_s16le`), `sample_rate`, `num_channels`, `language_hints`, `context.terms`,
/// `enable_endpoint_detection`, `enable_language_identification`; then binary audio; an empty
/// frame ends the stream, `{"type":"finalize"}` forces pending tokens final. Responses carry
/// `tokens` with `text`, `start_ms`, `end_ms`, `is_final`, `language`; final tokens come once and
/// never change, non-final ones are replaced by the next response; an `<end>` token marks the
/// endpoint. Streams last up to 300 minutes; 60+ languages including zh / ja / ko.
public struct SonioxConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String
    public var terms: [String]

    public init(baseURL: URL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!, apiKey: String?, model: String = "stt-rt-v5", terms: [String] = []) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.terms = terms
    }
}

public final class SonioxRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let config: SonioxConfig
    private let state: SonioxState

    public init(config: SonioxConfig) {
        self.config = config
        self.state = SonioxState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "soniox", displayName: "Soniox 实时识别", modelID: config.model, isLocal: false, dataDestination: "音频发送到 Soniox（美国）", costUnit: "按音频小时计费")
    }

    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .segment }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("Soniox 需要 API Key；请在 设置 › 引擎 › 识别 中填写。") }
        if config.model.isEmpty { return .blocked("Soniox 需要一个模型名称。") }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream { try await state.start(request) }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async { await state.finalize() }
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    public static func configFrame(config: SonioxConfig, language: String?) throws -> String {
        var body: [String: Any] = [
            "api_key": config.apiKey ?? "",
            "model": config.model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "enable_language_identification": language == nil,
        ]
        if let language { body["language_hints"] = [LanguageCode.soniox(language)] }
        if !config.terms.isEmpty { body["context"] = ["terms": config.terms] }
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// Final tokens accumulate, non-final ones replace the tail, `<end>` closes the sentence.
public struct SonioxParser: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case chunks([TranscriptChunk])
        case finished
        case failed(code: Int, message: String)
    }

    private struct Piece: Sendable {
        var text: String
        var start: Int
        var end: Int
    }

    private var settled: [Piece] = []
    private var interim: [Piece] = []

    public init() {}

    public var hasOpenSentence: Bool { !settled.isEmpty || !interim.isEmpty }

    public mutating func apply(_ json: [String: Any], anchorNs: Int64) -> Outcome {
        if let code = json["error_code"] as? Int {
            return .failed(code: code, message: json["error_message"] as? String ?? "")
        }
        func ns(_ ms: Int) -> Int64 { anchorNs + Int64(ms) * 1_000_000 }
        var out: [TranscriptChunk] = []
        var newInterim: [Piece] = []
        var closeAfter = false
        for t in json["tokens"] as? [[String: Any]] ?? [] {
            let text = t["text"] as? String ?? ""
            let final = (t["is_final"] as? Bool) == true
            if text == "<end>" {
                if final { closeAfter = true }
                continue
            }
            if text == "<fin>" || text.isEmpty { continue }
            let piece = Piece(text: text, start: t["start_ms"] as? Int ?? 0, end: t["end_ms"] as? Int ?? 0)
            if final { settled.append(piece) } else { newInterim.append(piece) }
        }
        interim = newInterim
        if closeAfter {
            if hasOpenSentence { out.append(current(ns: ns, isFinal: true)) }
            settled = []
            interim = []
        } else if hasOpenSentence, json["tokens"] != nil {
            out.append(current(ns: ns, isFinal: false))
        }
        if (json["finished"] as? Bool) == true {
            if hasOpenSentence { out.append(current(ns: ns, isFinal: true)); settled = []; interim = [] }
            return out.isEmpty ? .finished : .chunks(out)
        }
        return out.isEmpty ? .none : .chunks(out)
    }

    private func current(ns: (Int) -> Int64, isFinal: Bool) -> TranscriptChunk {
        let pieces = settled + interim
        let text = pieces.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        let start = pieces.first?.start ?? 0
        let end = max(start, pieces.last?.end ?? start)
        return TranscriptChunk(startNs: ns(start), endNs: ns(end), text: text, isFinal: isFinal)
    }
}

// MARK: - Socket session

actor SonioxState {
    private let config: SonioxConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var parser = SonioxParser()
    private var anchorNs: Int64?
    private var lastSendNs: Int64 = 0
    private var closed = true
    private var finished = false

    init(config: SonioxConfig) { self.config = config }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        let socket = WebSocketConnection(request: URLRequest(url: config.baseURL))
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "Soniox：\(error.message)")
        }
        self.socket = socket
        closed = false
        finished = false
        parser = SonioxParser()
        anchorNs = nil
        lastSendNs = MonotonicClock.nowNs()
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        do {
            try await socket.send(.text(try SonioxRecognizer.configFrame(config: config, language: request.sourceLanguage)))
        } catch {
            await teardown()
            throw ProviderError(.retryable, "Soniox：发送配置失败（\(error.localizedDescription)）")
        }
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.keepAliveIfIdle()
            }
        }
        log.notice("soniox open lane=\(request.laneID, privacy: .public) model=\(self.config.model, privacy: .public) lang=\(request.sourceLanguage ?? "auto", privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(SonioxRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func keepAliveIfIdle() async {
        guard !closed, let socket else { return }
        if MonotonicClock.nowNs() - lastSendNs > 10_000_000_000 {
            try? await socket.send(.text("{\"type\":\"keepalive\"}"))
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
        switch parser.apply(json, anchorNs: anchorNs ?? 0) {
        case .none: break
        case .chunks(let chunks):
            for c in chunks { events?.yield(.chunk(c)) }
            if (json["finished"] as? Bool) == true { finished = true }
        case .finished:
            finished = true
        case .failed(let code, let message):
            let cls: ProviderErrorClass = (400..<500).contains(code) ? .userFixable : .retryable
            events?.yield(.failed(ProviderError(cls, "Soniox：错误 \(code)\(message.isEmpty ? "" : "：\(message)")")))
        }
    }

    private func socketEnded(_ socket: WebSocketConnection) {
        guard !closed else { return }
        let why: String
        var classification: ProviderErrorClass = .retryable
        switch socket.closeInfo {
        case .code(let code, let reason): why = "连接已关闭（\(code)）\(reason.isEmpty ? "" : "：\(reason)")"
        case .error(let e):
            why = "连接中断：\(e)"
            if let status = socket.handshakeStatus, status == 401 || status == 403 { classification = .userFixable }
        case nil: why = "连接已关闭"
        }
        events?.yield(.failed(ProviderError(classification, "Soniox：\(why)")))
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        let pcm = PCM16.data(from: packet.mono)
        // An empty frame ends the stream on Soniox's side.
        guard !pcm.isEmpty else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        do {
            try await socket.send(.data(pcm))
            lastSendNs = MonotonicClock.nowNs()
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "Soniox：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    func finalize() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text("{\"type\":\"finalize\"}"))
        lastSendNs = MonotonicClock.nowNs()
    }

    func finish() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text(""))
        for _ in 0..<20 where !finished {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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

extension LanguageCode {
    /// Soniox hints are ISO-639-1 (`zh`, `ja`); script tags are dropped, Cantonese stays.
    static func soniox(_ code: String) -> String {
        let c = CaptionDomainBridge.canonical(code)
        if c == "yue" { return "yue" }
        return String(c.split(separator: "-").first ?? Substring(c))
    }
}
