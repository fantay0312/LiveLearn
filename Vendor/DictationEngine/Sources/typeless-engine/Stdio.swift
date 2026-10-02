import Foundation
import Darwin
import TypelessCore
import TypelessNet

/// Private parent/child channel. Credentials arrive only in the first stdin frame.
/// Unlike the diagnostic CLI, this mode never loads environment or another tool's config.
func cmdStdio(_ args: ParsedArgs) throws -> Int32 {
    guard args.flag("live") || args.flag("mock") else {
        throw CLIError("stdio requires explicit --live or --mock")
    }
    signal(SIGPIPE, SIG_IGN)
    let live = args.flag("live")
    let queue = DispatchQueue(label: "LiveLearn.dictation.engine", qos: .userInteractive)
    var adapter: AdapterConnection?
    var deadline: DispatchWorkItem?
    func emit(_ event: JSONValue) {
        FileHandle.standardOutput.write(Data(event.compactJSONBytes() + [10]))
    }
    func armDeadline(_ seconds: Double) {
        deadline?.cancel()
        let work = DispatchWorkItem {
            emit(errorFrame("语音引擎响应超时", code: "timeout"))
            adapter?.close()
            exit(1)
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    queue.sync { armDeadline(15) }
    var buffer = Data()
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = bytes.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress!, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= maxStartJSON else { throw CLIError("stdio frame exceeds limit") }
        while let end = buffer.firstIndex(of: 10) {
            let line = Array(buffer[..<end])
            buffer.removeSubrange(...end)
            queue.sync {
                do {
                    let frame = try JSONParser.parse(line)
                    if adapter == nil {
                        guard frame["type"] == .string("start") else { throw CLIError("first frame must be start") }
                        let profile: ASRProfile
                        if live {
                            guard let p = frame["profile"], let url = p["url"]?.stringValue,
                                  URL(string: url)?.scheme == "wss",
                                  let appKey = p["app_key"]?.stringValue, !appKey.isEmpty,
                                  let device = p["device_id"]?.stringValue, let number = Int64(device), number > 0,
                                  let appID = p["app_id"]?.stringValue, !appID.isEmpty else {
                                throw CLIError("请配置优化引擎的独立凭据、设备标识和 WSS 地址")
                            }
                            profile = ASRProfile(url: url, appKey: appKey, token: p["token"]?.stringValue ?? "", deviceId: device, appId: appID)
                        } else { profile = ASRProfile() }
                        let connection = AdapterConnection(profile: profile, mode: live ? "live" : "mock", engineFactory: {
                            let transport: ASRTransport = live ? LiveTransport(profile: profile, queue: queue) : MockTransport()
                            return try CoreEngine(profile: profile, transport: transport, queue: queue)
                        }, emit: { event in
                            var output = event
                            if event["type"] == .string("interim") || event["type"] == .string("correction"),
                               var fields = event.objectValue, let adapter {
                                fields["snapshot"] = .string(adapter.timeline.text)
                                output = .object(fields)
                            }
                            if event["type"] == .string("error") {
                                output = errorFrame("优化引擎连接或识别失败，请检查独立凭据及网络", code: "engine_failed")
                            }
                            emit(output)
                            if event["type"] == .string("ready") { armDeadline(15) }
                        })
                        adapter = connection
                        connection.onTerminal = {
                            deadline?.cancel()
                            connection.close()
                            exit(connection.emittedError ? 1 : 0)
                        }
                        try connection.onStart(frame)
                    } else if frame["type"] == .string("audio") {
                        guard let encoded = frame["pcm"]?.stringValue,
                              let pcm = Data(base64Encoded: encoded), pcm.count <= 65536, pcm.count % 2 == 0 else {
                            throw CLIError("invalid PCM frame")
                        }
                        try adapter?.onPCM(Array(pcm))
                        armDeadline(15)
                    } else if frame["type"] == .string("finish") {
                        try adapter?.onFinish()
                        armDeadline(15)
                    } else { throw CLIError("invalid stdio message") }
                } catch {
                    emit(errorFrame("语音引擎输入无效或启动失败", code: "invalid_request"))
                    adapter?.close()
                    exit(1)
                }
            }
        }
    }
    queue.sync { deadline?.cancel(); adapter?.close() }
    return 0
}
