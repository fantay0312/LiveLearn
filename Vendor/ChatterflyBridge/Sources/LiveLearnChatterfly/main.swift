import Foundation
import Network
import Darwin
import ChatterflyProtocol

final class Session {
    let queue = DispatchQueue(label: "LiveLearn.chatterfly", qos: .userInitiated)
    private var connection: NWConnection?
    private var audio: ChatterflyAudioFrames?
    private var transcript = ChatterflyTranscript()
    private var finishing = false
    private var ready = false
    private var deadline: DispatchWorkItem?
    private var terminal = false

    func emit(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        try? FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }

    func fail(_ message: String) {
        guard !terminal else { return }
        terminal = true
        emit(["type": "error", "message": message])
        connection?.cancel(); exit(1)
    }

    func arm(_ seconds: Double) {
        deadline?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail("Chatterfly 响应超时，已保留当前文字。") }
        deadline = work; queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func handle(_ json: [String: Any]) {
        do {
            switch json["type"] as? String {
            case "start":
                guard connection == nil, let profile = json["profile"] as? [String: Any],
                      let device = profile["device_id"] as? String, !device.isEmpty else { throw ChatterflyFailure.invalidConfiguration }
                let encrypted = try ChatterflyCipher.encrypt(ChatterflyConfiguration.request(deviceID: device, sessionID: UUID().uuidString))
                audio = try ChatterflyAudioFrames()
                let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.connectionTimeout = 10
                let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
                let websocket = NWProtocolWebSocket.Options(); websocket.autoReplyPing = true; websocket.maximumMessageSize = 1_048_576
                var headers = encrypted.headers
                if let token = profile["token"] as? String, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
                websocket.setAdditionalHeaders(headers.map { ($0.key, $0.value) })
                parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
                let connection = NWConnection(to: .url(ChatterflyConfiguration.endpoint), using: parameters)
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.receive()
                        self.send(Data(encrypted.text.utf8), opcode: .text) {
                            self.ready = true; self.arm(20)
                            self.emit(["type": "ready", "mode": "live", "engine": "chatterfly"])
                        }
                    case .failed: self.fail("无法连接 Chatterfly，请检查网络或账户 Token。")
                    default: break
                    }
                }
                arm(15); connection.start(queue: queue)
            case "audio":
                guard ready, !finishing, let raw = json["pcm"] as? String, let data = Data(base64Encoded: raw), data.count <= 65536,
                      data.count % 2 == 0, let audio else { throw ChatterflyFailure.audio }
                let encoded = try audio.append(data)
                if !encoded.isEmpty { send(encoded, opcode: .binary) }
                arm(20)
            case "finish":
                guard ready, !finishing, let audio else { throw ChatterflyFailure.invalidConfiguration }
                finishing = true
                let tail = try audio.append(Data(), finish: true)
                if !tail.isEmpty { send(tail, opcode: .binary) }
                send(Data("{}".utf8), opcode: .text)
                arm(8)
            default: throw ChatterflyFailure.invalidConfiguration
            }
        } catch { fail("Chatterfly 配置、加密或音频格式无效。") }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, completion: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        connection?.send(content: data, contentContext: .init(identifier: UUID().uuidString, metadata: [metadata]), isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail("Chatterfly 连接中断。") } else { completion?() }
        })
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.terminal else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close {
                guard self.finishing, self.transcript.isFullyFinal else { self.fail("Chatterfly 提前结束或没有返回最终识别结果。"); return }
                let accepted: Set<NWProtocolWebSocket.CloseCode.Defined> = [.normalClosure, .goingAway, .noStatusReceived]
                guard case .protocolCode(let code) = metadata!.closeCode, accepted.contains(code) else {
                    self.fail("Chatterfly 异常关闭，已保留当前文字。"); return
                }
                self.terminal = true; self.deadline?.cancel()
                self.emit(["type": "final", "text": self.transcript.text, "asr_finished": true])
                self.connection?.cancel(); exit(0)
            }
            if error != nil { self.fail("Chatterfly 网络连接异常。请检查网络或账户 Token。"); return }
            if let data, !data.isEmpty, metadata?.opcode == .text || metadata?.opcode == .binary {
                do {
                    let text = try self.transcript.receive(data)
                    self.emit(["type": "correction", "snapshot": text])
                } catch ChatterflyFailure.server(let code) {
                    if CommandLine.arguments.contains("--diagnostics"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                        self.emit(["type": "diagnostic", "server_code": code,
                                   "server_message": message.replacingOccurrences(of: #"[A-Za-z0-9+/_=\-]{24,}"#, with: "<opaque>", options: .regularExpression)])
                    }
                    self.fail(code == 16 ? "Chatterfly 登录未通过，请检查账户 Token。" : "Chatterfly 返回错误 \(code)，请重新说话。"); return
                } catch {
                    if CommandLine.arguments.contains("--diagnostics") {
                        let preview = String(decoding: data.prefix(240), as: UTF8.self)
                            .replacingOccurrences(of: #"[A-Za-z0-9+/_=\-]{24,}"#, with: "<opaque>", options: .regularExpression)
                        self.emit(["type": "diagnostic", "bytes": data.count, "preview": preview, "frame": data.base64EncodedString(), "error": String(describing: error)])
                        self.receive(); return
                    }
                    self.fail("Chatterfly 返回了无法识别的响应。"); return
                }
            }
            self.receive()
        }
    }
}

if CommandLine.arguments.contains("--self-check") {
    do {
        _ = try ChatterflyCipher.publicKey()
        let frames = try ChatterflyAudioFrames().append(Data(count: 640))
        let config = try ChatterflyCipher.encrypt(ChatterflyConfiguration.request(deviceID: "self-check", sessionID: "self-check"))
        let result: [String: Any] = ["ok": !frames.isEmpty && !config.text.isEmpty, "resource": ChatterflyCipher.resourcePath]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result)); exit(0)
    } catch { exit(1) }
}
guard CommandLine.arguments.contains("--live") else { exit(2) }
signal(SIGPIPE, SIG_IGN)
let session = Session()
session.queue.sync { session.arm(15) }
var pending = Data(), bytes = [UInt8](repeating: 0, count: 8192)
while true {
    let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count) }
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { break }
    pending.append(contentsOf: bytes.prefix(count))
    guard pending.count <= 1_048_576 else { exit(2) }
    while let end = pending.firstIndex(of: 10) {
        let data = Data(pending[..<end]); pending.removeSubrange(...end)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { exit(2) }
        session.queue.sync { session.handle(json) }
    }
}
exit(0)
