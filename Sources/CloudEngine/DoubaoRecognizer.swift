import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "doubao")

/// 豆包 (Volcengine) streaming speech recognition, "大模型流式语音识别" (sauc / bigmodel).
///
/// Wire facts (official doc 6561/1354869, updated 2026-08, cross-checked against the vendor's
/// Python demo and two open-source Swift clients): `wss://openspeech.bytedance.com/api/v3/sauc/
/// bigmodel_async` (replies when the result changes; `bigmodel` replies per packet), headers
/// `X-Api-App-Key` + `X-Api-Access-Key` (old console) or one `X-Api-Key` (new console), plus
/// `X-Api-Resource-Id`, `X-Api-Connect-Id`, `X-Api-Request-Id`. Every frame is binary: a
/// 4-byte header (version 1, header size 1 × 4, message type, flags, serialization JSON,
/// compression), an optional int32 sequence, a uint32 payload size, the payload. The first
/// frame is the full client request (JSON), then 16 kHz PCM16 audio packets numbered from 2,
/// the last one with a negative sequence. Results carry `result.utterances` with millisecond
/// times and a `definite` flag. The streaming modes take no language: Chinese and English only.
public struct DoubaoConfig: Sendable, Equatable {
    public var baseURL: URL
    /// App ID from the old console; empty means the token is a new-console API key.
    public var appKey: String?
    /// Access Token (old console) or API key (new console).
    public var accessKey: String?
    /// `volc.bigasr.sauc.duration` (1.0, ¥4.5/h) or `volc.seedasr.sauc.duration` (2.0, ¥1/h).
    public var resourceID: String
    public var hotWords: [String]
    public var enableNonstream = false

    public init(baseURL: URL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!, appKey: String?, accessKey: String?, resourceID: String = "volc.bigasr.sauc.duration", hotWords: [String] = []) {
        self.baseURL = baseURL
        self.appKey = appKey
        self.accessKey = accessKey
        self.resourceID = resourceID
        self.hotWords = hotWords
    }
}

public final class DoubaoRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let sampleRate = 16_000
    public let config: DoubaoConfig
    private let state: DoubaoState

    public init(config: DoubaoConfig) {
        self.config = config
        self.state = DoubaoState(config: config)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "doubao.sauc", displayName: "豆包流式识别", modelID: "bigmodel", isLocal: false, dataDestination: "音频发送到火山引擎（中国）", costUnit: "按音频小时计费")
    }

    /// Mixed Chinese / English is what the model does; there is no language switch.
    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .segment }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if (config.accessKey ?? "").isEmpty { return .blocked("豆包流式识别需要 Access Token 或 API Key；请在 设置 › 引擎 › 识别 中填写。") }
        if let code = sourceLanguage, !LanguageCode.doubaoSupports(code) {
            return .blocked("豆包流式识别只支持中文和英文，不支持\(CaptionDomainBridge.name(code))；请换一种源语言或改用其他识别引擎。")
        }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream { try await state.start(request) }
    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async {}
    public func finish() async throws { try await state.finish() }
    public func cancel() async { await state.cancel() }

    // MARK: - Wire format (pure, tested)

    public static func headers(config: DoubaoConfig, connectID: String, requestID: String) -> [String: String] {
        var h: [String: String] = [
            "X-Api-Resource-Id": config.resourceID,
            "X-Api-Connect-Id": connectID,
            "X-Api-Request-Id": requestID,
        ]
        if let app = config.appKey, !app.isEmpty {
            h["X-Api-App-Key"] = app
            h["X-Api-Access-Key"] = config.accessKey ?? ""
        } else {
            h["X-Api-Key"] = config.accessKey ?? ""
        }
        return h
    }

    public static func fullClientRequest(config: DoubaoConfig, uid: String = "livelearn") throws -> Data {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": false,
            "show_utterances": true,
            "result_type": "full",
            "end_window_size": 800,
            "force_to_speech_time": 1000,
        ]
        if config.enableNonstream { request["enable_nonstream"] = true }
        if !config.hotWords.isEmpty {
            let context = try JSONSerialization.data(withJSONObject: ["hotwords": config.hotWords.map { ["word": $0] }], options: [.sortedKeys])
            request["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        let body: [String: Any] = [
            "user": ["uid": uid],
            "audio": ["format": "pcm", "codec": "raw", "rate": sampleRate, "bits": 16, "channel": 1],
            "request": request,
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

/// The binary framing. Header byte 0 is version 1 / header size 1 (`0x11`); byte 1 is the
/// message type in the high nibble and flags in the low one; byte 2 is serialization (JSON =
/// 1, raw = 0) high and compression (none = 0, gzip = 1) low; byte 3 is reserved.
public enum DoubaoFrame {
    public static let fullClient: UInt8 = 0b0001
    public static let audioOnly: UInt8 = 0b0010
    public static let fullServer: UInt8 = 0b1001
    public static let error: UInt8 = 0b1111

    public struct Incoming: Equatable, Sendable {
        public var type: UInt8
        public var flags: UInt8
        public var sequence: Int32?
        public var payload: Data
        public var errorCode: UInt32?
        /// The server's last packet: the "last" flag or a negative sequence.
        public var isLast: Bool { flags & 0b0010 != 0 || (sequence ?? 0) < 0 }
    }

    /// The first frame: JSON, sequence 1.
    public static func fullClientRequest(_ json: Data) -> Data {
        frame(type: fullClient, flags: 0b0001, serialization: 1, sequence: 1, payload: json)
    }

    /// An audio packet; the last one carries a negative sequence and the "last" flag.
    public static func audio(_ pcm: Data, sequence: Int32, last: Bool) -> Data {
        frame(type: audioOnly, flags: last ? 0b0011 : 0b0001, serialization: 0, sequence: last ? -abs(sequence) : sequence, payload: pcm)
    }

    static func frame(type: UInt8, flags: UInt8, serialization: UInt8, sequence: Int32?, payload: Data) -> Data {
        var out = Data([0x11, (type << 4) | flags, serialization << 4, 0x00])
        if let sequence { out.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init)) }
        out.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init))
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> Incoming {
        let b = [UInt8](data)
        guard b.count >= 4 else { throw DoubaoFrameError.truncated }
        let headerSize = Int(b[0] & 0x0F) * 4
        let type = b[1] >> 4
        let flags = b[1] & 0x0F
        let compression = b[2] & 0x0F
        var offset = headerSize
        func u32() throws -> UInt32 {
            guard offset + 4 <= b.count else { throw DoubaoFrameError.truncated }
            let v = UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16 | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
            offset += 4
            return v
        }
        if type == error {
            let code = try u32()
            let size = Int(try u32())
            guard offset + size <= b.count else { throw DoubaoFrameError.truncated }
            return Incoming(type: type, flags: flags, sequence: nil, payload: Data(b[offset..<(offset + size)]), errorCode: code)
        }
        var sequence: Int32?
        if flags & 0b0001 != 0 { sequence = Int32(bitPattern: try u32()) }
        let size = Int(try u32())
        guard offset + size <= b.count else { throw DoubaoFrameError.truncated }
        var payload = Data(b[offset..<(offset + size)])
        if compression == 1 { payload = try Gzip.inflate(payload) }
        return Incoming(type: type, flags: flags, sequence: sequence, payload: payload, errorCode: nil)
    }

    public enum DoubaoFrameError: Error { case truncated }
}

/// Utterances with `definite: true` are sentences the server will not change again; the rest
/// is the sentence in progress. `result_type: full` repeats all of them, so finals are keyed.
public struct DoubaoParser: Sendable {
    private var emitted: Set<String> = []

    public init() {}

    public mutating func apply(_ json: [String: Any], anchorNs: Int64) -> [TranscriptChunk] {
        guard let result = json["result"] as? [String: Any] else { return [] }
        func ns(_ ms: Int) -> Int64 { anchorNs + Int64(ms) * 1_000_000 }
        var out: [TranscriptChunk] = []
        guard let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty else {
            if let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                let end = (json["audio_info"] as? [String: Any])?["duration"] as? Int ?? 0
                out.append(TranscriptChunk(startNs: ns(max(0, end - 2000)), endNs: ns(end), text: text, isFinal: false))
            }
            return out
        }
        var pending: [[String: Any]] = []
        for u in utterances {
            let text = (u["text"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let start = u["start_time"] as? Int ?? 0
            let end = max(start, u["end_time"] as? Int ?? start)
            if (u["definite"] as? Bool) == true {
                let key = "\(start)-\(end)-\(text)"
                guard !text.isEmpty, emitted.insert(key).inserted else { continue }
                out.append(TranscriptChunk(startNs: ns(start), endNs: ns(end), text: text, isFinal: true))
            } else if !text.isEmpty {
                pending.append(u)
            }
        }
        if let first = pending.first, let last = pending.last {
            let text = pending.map { ($0["text"] as? String ?? "").trimmingCharacters(in: .whitespaces) }.joined()
            let start = first["start_time"] as? Int ?? 0
            let end = max(start, last["end_time"] as? Int ?? start)
            out.append(TranscriptChunk(startNs: ns(start), endNs: ns(end), text: text, isFinal: false))
        }
        return out
    }
}

// MARK: - Socket session

actor DoubaoState {
    private let config: DoubaoConfig
    private var socket: WebSocketConnection?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var parser = DoubaoParser()
    private var anchorNs: Int64?
    private var sequence: Int32 = 1
    private var closed = true
    private var readyReceived = false
    private var sessionFailure: ProviderError?
    private var lastSeen = false

    init(config: DoubaoConfig) { self.config = config }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        var req = URLRequest(url: config.baseURL)
        for (k, v) in DoubaoRecognizer.headers(config: config, connectID: UUID().uuidString, requestID: UUID().uuidString) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let socket = WebSocketConnection(request: req)
        do {
            try await socket.open()
        } catch let error as ProviderError {
            throw ProviderError(error.classification, "豆包：\(error.message)")
        }
        self.socket = socket
        closed = false
        readyReceived = false
        sessionFailure = nil
        lastSeen = false
        parser = DoubaoParser()
        anchorNs = nil
        sequence = 1
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        receiveTask = Task { [weak self] in await self?.receiveLoop(socket) }
        do {
            let body = try DoubaoRecognizer.fullClientRequest(config: config)
            try await socket.send(.data(DoubaoFrame.fullClientRequest(body)))
            // The server answers the configuration first; a bad key or resource shows up here.
            let deadline = ContinuousClock.now + .seconds(8)
            while !readyReceived, !closed, sessionFailure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            if let sessionFailure { throw sessionFailure }
            guard readyReceived, !closed else { throw ProviderError(.retryable, "等待服务器确认会话超时或会话已取消") }
        } catch {
            await teardown()
            if let p = error as? ProviderError { throw ProviderError(p.classification, "豆包：\(p.message)") }
            throw ProviderError(.retryable, "豆包：发送会话配置失败（\(error.localizedDescription)）")
        }
        log.notice("doubao open lane=\(request.laneID, privacy: .public) resource=\(self.config.resourceID, privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(DoubaoRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    private func receiveLoop(_ socket: WebSocketConnection) async {
        while !Task.isCancelled, let message = await socket.receive() {
            guard case .data(let data) = message else { continue }
            handle(data)
        }
        socketEnded(socket)
    }

    private func handle(_ data: Data) {
        guard !closed else { return }
        let frame: DoubaoFrame.Incoming
        do {
            frame = try DoubaoFrame.decode(data)
        } catch {
            log.error("doubao frame undecodable: \(String(describing: error), privacy: .public)")
            return
        }
        if frame.type == DoubaoFrame.error, let code = frame.errorCode {
            let message = String(decoding: frame.payload, as: UTF8.self)
            let cls: ProviderErrorClass = (45_000_000..<46_000_000).contains(Int(code)) && code != 45_000_081 ? .userFixable : .retryable
            let error = ProviderError(cls, "豆包：错误 \(code)\(message.isEmpty ? "" : "：\(message)")")
            sessionFailure = error
            events?.yield(.failed(error))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else { return }
        if let code = json["code"] as? Int, code != 20_000_000, code != 0 {
            let message = json["message"] as? String ?? ""
            let error = ProviderError(.retryable, "豆包：状态 \(code)\(message.isEmpty ? "" : "：\(message)")")
            sessionFailure = error
            events?.yield(.failed(error))
            return
        }
        readyReceived = true
        if frame.isLast { lastSeen = true }
        for chunk in parser.apply(json, anchorNs: anchorNs ?? 0) {
            events?.yield(.chunk(chunk))
        }
    }

    private func socketEnded(_ socket: WebSocketConnection) {
        guard !closed, !lastSeen else { return }
        let why: String
        var classification: ProviderErrorClass = .retryable
        switch socket.closeInfo {
        case .code(let code, let reason):
            why = "连接已关闭（\(code)）\(reason.isEmpty ? "" : "：\(reason)")"
        case .error(let e):
            why = "连接中断：\(e)"
            if let status = socket.handshakeStatus, status == 401 || status == 403 || status == 400 { classification = .userFixable }
        case nil:
            why = "连接已关闭"
        }
        let error = ProviderError(classification, "豆包：\(why)")
        sessionFailure = error
        events?.yield(.failed(error))
    }

    func push(_ packet: ProviderAudioPacket) async {
        guard !closed, let socket else { return }
        let pcm = PCM16.data(from: packet.mono)
        guard !pcm.isEmpty else { return }
        if anchorNs == nil { anchorNs = packet.sourceStartNs }
        sequence += 1
        do {
            try await socket.send(.data(DoubaoFrame.audio(pcm, sequence: sequence, last: false)))
        } catch {
            guard !closed else { return }
            events?.yield(.failed(ProviderError(.retryable, "豆包：发送音频失败（\(error.localizedDescription)）")))
        }
    }

    func finish() async throws {
        guard !closed, let socket else { return }
        // The last packet: 100 ms of silence with a negative sequence, so the server flushes.
        sequence += 1
        let tail = PCM16.data(from: Array(repeating: 0, count: DoubaoRecognizer.sampleRate / 10))
        do {
            try await socket.send(.data(DoubaoFrame.audio(tail, sequence: sequence, last: true)))
            let deadline = ContinuousClock.now + .seconds(config.enableNonstream ? 8 : 3)
            while !lastSeen, !closed, sessionFailure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            if let sessionFailure { throw sessionFailure }
            guard lastSeen else { throw ProviderError(.retryable, "豆包未在时限内返回终稿；已保留当前识别文字。") }
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    func cancel() async { await teardown() }

    private func teardown() async {
        closed = true
        receiveTask?.cancel()
        receiveTask = nil
        socket?.close()
        socket = nil
        events?.finish()
        events = nil
    }
}

extension LanguageCode {
    /// 豆包's streaming modes recognize Mandarin (with dialects) and English, nothing else.
    static func doubaoSupports(_ code: String) -> Bool {
        let c = CaptionDomainBridge.canonical(code)
        return c.hasPrefix("zh") || c == "yue" || c == "en"
    }
}
