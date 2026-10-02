import Foundation
import Darwin
import AudioDomain
import CaptionDomain
import EngineKit
import ProviderAdapters

public struct TypelessProcessConfig: Sendable {
    public enum Backend: Sendable { case doubao, chatterfly }
    public var backend: Backend
    public var executable: URL
    public var url: String
    public var appKey: String
    public var token: String
    public var deviceID: String
    public var appID: String

    public init(executable: URL, url: String, appKey: String, token: String, deviceID: String, appID: String, backend: Backend = .doubao) {
        self.backend = backend
        self.executable = executable; self.url = url; self.appKey = appKey
        self.token = token; self.deviceID = deviceID; self.appID = appID
    }
}

public actor TypelessProcessRecognizer: SpeechRecognizer {
    public nonisolated let descriptor: EngineStageDescriptor
    public nonisolated let supportsAutoDetect = true
    private let config: TypelessProcessConfig
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncStream<RecognizerEvent>.Continuation?
    private var buffer = Data()
    private var ready = false
    private var terminal = false
    private var failure: ProviderError?
    private var revision: Int64 = 0
    private var generation = UUID()

    public init(config: TypelessProcessConfig) {
        self.config = config
        descriptor = config.backend == .chatterfly
            ? EngineStageDescriptor(id: "chatterfly", displayName: "Chatterfly", modelID: "Chatterfly streaming", isLocal: false, dataDestination: "音频发送到 Chatterfly（腾讯）", costUnit: "以服务政策为准")
            : EngineStageDescriptor(id: "typeless.frontier", displayName: "豆包输入法优化引擎", modelID: "Frontier", isLocal: false, dataDestination: "音频发送到豆包输入法服务", costUnit: "以服务账户为准")
    }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        guard #available(macOS 26, *) else { return .blocked("优化引擎需要 macOS 26；可选择其他本地或云端引擎。") }
        guard FileManager.default.isExecutableFile(atPath: config.executable.path) else { return .blocked("未找到已打包的语音优化引擎，请重新构建 LiveLearn。") }
        if config.backend == .chatterfly {
            guard !config.token.isEmpty else { return .blocked("Chatterfly 需要授权 Token，请在语音输入的「引擎连接」中填写。") }
            if let language = sourceLanguage, !language.hasPrefix("zh"), !language.hasPrefix("en") {
                return .blocked("Chatterfly 当前接入中文与中英混说，请选择中文或自动语言。")
            }
            return config.deviceID.isEmpty ? .blocked("Chatterfly 设备标识未初始化。") : .ready
        }
        guard URL(string: config.url)?.scheme == "wss", !config.appKey.isEmpty,
              let device = Int64(config.deviceID), device > 0, !config.appID.isEmpty else {
            return .blocked("请在语音输入设置中填写优化引擎的独立凭据和设备标识。")
        }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        if let blocker = await availability(sourceLanguage: request.sourceLanguage).blocker { throw ProviderError(.userFixable, blocker) }
        await cancel()
        let id = UUID(); generation = id
        ready = false; terminal = false; failure = nil; revision = 0; buffer.removeAll()
        let stream = AsyncStream<RecognizerEvent>(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = config.executable
        child.arguments = ["stdio", "--live"]
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        do { try child.run() } catch {
            await cancel()
            throw ProviderError(.userFixable, "无法启动优化引擎，请检查构建和签名。")
        }
        process = child
        // Close the parent's duplicate child ends so EOF reflects the child's actual lifetime.
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
        let handle = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            defer { try? handle.close() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while !Task.isCancelled {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                await self?.receive(Data(bytes.prefix(count)), generation: id)
            }
            await self?.ended(generation: id)
        }
        do {
            try send(["type": "start", "context": "", "hotwords": request.vocabulary, "two_pass": true,
                      "profile": ["url": config.url, "app_key": config.appKey, "token": config.token,
                                  "device_id": config.deviceID, "app_id": config.appID]])
            let deadline = ContinuousClock.now + .seconds(16)
            while !ready, !terminal, generation == id, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard generation == id else { throw CancellationError() }
            if let failure { throw failure }
            guard ready, !terminal else { throw ProviderError(.retryable, "优化引擎启动超时或提前退出。") }
            return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: 16000, channelCount: 1), events: stream)
        } catch { await cancel(); throw error }
    }

    public func push(_ packet: ProviderAudioPacket) async {
        guard ready, !terminal else { return }
        do { try send(["type": "audio", "pcm": PCM16.data(from: packet.mono).base64EncodedString()]) }
        catch { fail("语音引擎连接中断。") }
    }

    public func finalizePending() async { }

    public func finish() async throws {
        let id = generation
        guard !terminal else { if let failure { throw failure }; return }
        try send(["type": "finish"])
        let deadline = ContinuousClock.now + .seconds(17)
        while !terminal, generation == id, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard generation == id else { throw CancellationError() }
        if let failure { throw failure }
        guard terminal else { await cancel(); throw ProviderError(.retryable, "优化引擎收尾超时，已保留当前文字。") }
    }

    public func cancel() async {
        generation = UUID(); terminal = true; ready = false
        reader?.cancel(); reader = nil
        try? input?.close(); input = nil
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        // The reader owns the output descriptor until EOF; closing it here can race a new
        // session reusing the same descriptor. Terminating the child unblocks the read.
        output = nil
        continuation?.finish(); continuation = nil
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw CancellationError() }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data, generation id: UUID) {
        guard id == generation, !terminal else { return }
        buffer.append(data)
        guard buffer.count <= 1_048_576 else { fail("语音引擎回复超过限制。"); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = json["type"] as? String else {
                fail("语音引擎回复格式无效。"); return
            }
            switch type {
            case "ready":
                guard json["mode"] as? String == "live" else { fail("优化引擎返回模拟结果，已拒绝输入。"); return }
                if config.backend == .chatterfly, json["engine"] as? String != "chatterfly" { fail("Chatterfly 引擎标识不匹配。"); return }
                ready = true
            case "interim", "correction", "final":
                guard ready, let text = (type == "final" ? json["text"] : json["snapshot"]) as? String,
                      type != "final" || json["asr_finished"] as? Bool == true else { fail("语音引擎缺少完整修订结果。"); return }
                revision += 1
                continuation?.yield(.chunk(TranscriptChunk(startNs: 0, endNs: revision, text: text, isFinal: type == "final")))
                if type == "final" { terminal = true; continuation?.finish() }
            case "error":
                if config.backend == .chatterfly { fail(json["message"] as? String ?? "Chatterfly 识别失败。") }
                else { fail("优化引擎识别失败，请检查独立凭据及网络。") }
            default: fail("语音引擎返回未知事件。")
            }
        }
    }

    private func ended(generation id: UUID) {
        if id == generation, !terminal { fail("语音引擎提前退出，已保留当前文字。") }
    }

    private func fail(_ message: String) {
        guard !terminal else { return }
        let error = ProviderError(.retryable, message)
        failure = error; terminal = true
        continuation?.yield(.failed(error)); continuation?.finish()
    }
}
