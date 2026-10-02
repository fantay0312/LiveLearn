import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "paraformer")

/// 阿里云百炼 (DashScope) real-time recognition: Paraformer (`paraformer-realtime-v2`) and the
/// newer `fun-asr-realtime`, which speak the same protocol.
///
/// Wire facts (official doc "websocket-for-paraformer-real-time-service", 2026-09):
/// `wss://dashscope.aliyuncs.com/api-ws/v1/inference`, `Authorization: bearer <key>` (the same
/// key as the chat models), a `run-task` JSON with `streaming: duplex`, then binary PCM16 frames,
/// then `finish-task`. Events: `task-started`, `result-generated` (one `sentence` with
/// `begin_time` / `end_time` ms and `sentence_end`), `task-finished`, `task-failed`. Language
/// hints: zh, en, ja, yue, ko, de, fr, ru; none means the model decides.
public struct ParaformerConfig: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String?
    public var model: String

    public init(baseURL: URL = URL(string: "wss://dashscope.aliyuncs.com/api-ws/v1/inference")!, apiKey: String?, model: String = "paraformer-realtime-v2") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

public final class ParaformerRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let config: ParaformerConfig
    private let state: ParaformerState

    public init(config: ParaformerConfig) {
        self.config = config
        self.state = ParaformerState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "dashscope.asr", displayName: "阿里云实时识别", modelID: config.model, isLocal: false, dataDestination: "音频发送到阿里云百炼（中国）", costUnit: "按音频时长计费")
    }

    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .segment }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("阿里云实时识别需要百炼 API Key；请在 设置 › 引擎 › 识别 中填写（与通义千问翻译共用）。") }
        if config.model.isEmpty { return .blocked("阿里云实时识别需要一个模型名称。") }
        if let code = sourceLanguage, LanguageCode.paraformer(code) == nil {
            return .blocked("阿里云实时识别不支持\(CaptionDomainBridge.name(code))（支持中、英、日、粤、韩、德、法、俄）；请换一种源语言或改用其他识别引擎。")
        }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream { try await state.start(request) }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async {}
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    public static func runTask(config: ParaformerConfig, taskID: String, language: String?) throws -> String {
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": sampleRate]
        if let language, let hint = LanguageCode.paraformer(language) { parameters["language_hints"] = [hint] }
        let body: [String: Any] = [
            "header": ["action": "run-task", "task_id": taskID, "streaming": "duplex"],
            "payload": [
                "task_group": "audio", "task": "asr", "function": "recognition",
                "model": config.model, "parameters": parameters, "input": [String: Any](),
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }

    public static func finishTask(taskID: String) -> String {
        "{\"header\":{\"action\":\"finish-task\",\"streaming\":\"duplex\",\"task_id\":\"\(taskID)\"},\"payload\":{\"input\":{}}}"
    }
}

/// Each `result-generated` carries the sentence in progress; `sentence_end` closes it.
public struct ParaformerParser: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case started
        case chunk(TranscriptChunk)
        case finished
        case failed(code: String, message: String)
    }

    public init() {}

    public func apply(_ json: [String: Any], anchorNs: Int64) -> Outcome {
        guard let header = json["header"] as? [String: Any], let event = header["event"] as? String else { return .none }
        func ns(_ ms: Int) -> Int64 { anchorNs + Int64(ms) * 1_000_000 }
        switch event {
        case "task-started": return .started
        case "task-finished": return .finished
        case "task-failed":
            return .failed(code: header["error_code"] as? String ?? "", message: header["error_message"] as? String ?? "")
        case "result-generated":
            guard let payload = json["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return .none }
            let text = (sentence["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return .none }
            let begin = sentence["begin_time"] as? Int ?? 0
            let end = max(begin, sentence["end_time"] as? Int ?? begin)
            let final = (sentence["sentence_end"] as? Bool) == true
            return .chunk(TranscriptChunk(startNs: ns(begin), endNs: ns(end), text: text, isFinal: final))
        default: return .none
        }
    }
}

// MARK: - Socket session

actor ParaformerState {
    private let config: ParaformerConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private let parser = ParaformerParser()
    private var anchorNs: Int64?
    private var taskID = ""
    private var closed = true
    private var finished = false
    private var readyContinuation: CheckedContinuation<Void, Error>?

    init(config: ParaformerConfig) { self.config = config }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        var req = URLRequest(url: config.baseURL)
        req.setValue("bearer \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        let socket = WebSocketConnection(request: req)
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "阿里云：\(error.message)")
        }
        self.socket = socket
        closed = false
        finished = false
        anchorNs = nil
        taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        do {
            try await socket.send(.text(try ParaformerRecognizer.runTask(config: config, taskID: taskID, language: request.sourceLanguage)))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in try await self?.awaitReady() }
                group.addTask { try await Task.sleep(nanoseconds: 8_000_000_000); throw ProviderError(.retryable, "等待 task-started 超时") }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            await teardown()
            if let p = error as? ProviderError { throw ProviderError(p.classification, "阿里云：\(p.message)") }
            throw ProviderError(.retryable, "阿里云：发送 run-task 失败（\(error.localizedDescription)）")
        }
        log.notice("paraformer open lane=\(request.laneID, privacy: .public) model=\(self.config.model, privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(ParaformerRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func awaitReady() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in readyContinuation = c }
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
        case .started:
            if let c = readyContinuation { readyContinuation = nil; c.resume() }
        case .chunk(let chunk):
            events?.yield(.chunk(chunk))
        case .finished:
            finished = true
        case .failed(let code, let message):
            let cls: ProviderErrorClass = ["InvalidApiKey", "InvalidParameter", "Arrearage", "AccessDenied", "Unauthorized"].contains(code) ? .userFixable : .retryable
            let error = ProviderError(cls, "阿里云：\(code) \(message)")
            if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: error) } else { events?.yield(.failed(error)) }
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
        let error = ProviderError(classification, "阿里云：\(why)")
        if let c = readyContinuation { readyContinuation = nil; c.resume(throwing: error) } else { events?.yield(.failed(error)) }
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        let pcm = PCM16.data(from: packet.mono)
        guard !pcm.isEmpty else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        do {
            try await socket.send(.data(pcm))
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "阿里云：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    func finish() async {
        guard !closed, let socket else { return }
        try? await socket.send(.text(ParaformerRecognizer.finishTask(taskID: taskID)))
        for _ in 0..<20 where !finished {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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

extension LanguageCode {
    /// DashScope language hints; nil when the model has no such language.
    static func paraformer(_ code: String) -> String? {
        switch CaptionDomainBridge.canonical(code) {
        case "zh-Hans", "zh-Hant": return "zh"
        case "yue": return "yue"
        case "en", "ja", "ko", "de", "fr", "ru": return CaptionDomainBridge.canonical(code)
        default: return nil
        }
    }
}
