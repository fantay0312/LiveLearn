// Offline mock ASR remote with StartTask → FinishSession ordering (spec §27.1). Same state
// order and payload shapes as the Python `mock.py`.

public let mockFinalText = "模拟识别结果"
public let mockPassTexts: [Int: [String]] = [
    1: ["模拟识别结果"],
    2: ["模拟识别", "模拟识别结果"],
    3: ["模拟识别", "模拟识别修订", "模拟识别结果"],
]

public final class MockASRRemote {
    public private(set) var state = "WAIT_START_TASK"
    public private(set) var taskId = ""
    public var twoPass = true
    public var threePass = false
    public private(set) var audioFrames = 0
    public var finalText: String
    public private(set) var finished = false

    public init(finalText: String = mockFinalText) { self.finalText = finalText }

    public var passCount: Int { threePass ? 3 : (twoPass ? 2 : 1) }

    public func texts() -> [String] {
        var texts = mockPassTexts[passCount]!
        texts[texts.count - 1] = finalText
        return texts
    }

    private func response(_ event: String, payload: [UInt8] = [], seqId: UInt64 = 0, statusCode: UInt64 = 0) -> WebSocketResponse {
        WebSocketResponse(taskId: taskId, namespace: "ASR", event: event, statusCode: statusCode, payload: payload, seqId: seqId)
    }

    private func asrPayload(isInterim: Bool, seqId: UInt64) -> [UInt8] {
        var results: [JSONValue] = []
        for text in texts() {
            results.append(.obj([
                ("text", .string(text)),
                ("is_interim", .bool(isInterim)),
                ("start_time", .double(0.0)),
                ("end_time", .double(max(0.04 * Double(audioFrames), 0.04))),
                ("is_vad_finished", .bool(!isInterim)),
                ("extra", .obj([("seq_id", .int(Int64(seqId)))])),
            ]))
        }
        return JSONValue.obj([("results", .array(results)), ("extra", .obj([("seq_id", .int(Int64(seqId)))]))]).compactJSONBytes()
    }

    private func abort(_ got: String) -> [WebSocketResponse] {
        state = "FAILED"
        let payload = JSONValue.obj([("error", .string("unexpected event \(got)"))]).compactJSONBytes()
        return [response("SessionFailed", payload: payload, statusCode: 1)]
    }

    public func handle(_ request: WebSocketRequest) -> [WebSocketResponse] {
        let event = request.event
        let label = event.isEmpty ? "<empty>" : event
        if !taskId.isEmpty, !request.taskId.isEmpty, request.taskId != taskId { return abort(label) }
        switch state {
        case "WAIT_START_TASK":
            guard event == "StartTask" else { return abort(label) }
            taskId = request.taskId
            state = "WAIT_START_SESSION"
            return [response("TaskStarted")]
        case "WAIT_START_SESSION":
            guard event == "StartSession" else { return abort(label) }
            ingestStartSession(request)
            state = "STREAMING"
            return [response("SessionStarted")]
        case "STREAMING":
            if event == "TaskRequest" {
                audioFrames += 1
                let seq = request.seqId
                return [response("ASRResponse", payload: asrPayload(isInterim: true, seqId: seq), seqId: seq)]
            }
            if event == "FinishSession" {
                state = "FINISHED"
                finished = true
                let seq = UInt64(max(audioFrames, 1))
                return [
                    response("ASRResponse", payload: asrPayload(isInterim: false, seqId: seq), seqId: seq),
                    response("SessionFinished", seqId: seq),
                ]
            }
            return abort(label)
        default:
            return abort(label)
        }
    }

    private func ingestStartSession(_ request: WebSocketRequest) {
        guard !request.payload.isEmpty, let obj = try? JSONParser.parse(request.payload),
              let extra = obj["extra"]?.objectValue else { return }
        if let v = extra["enable_asr_twopass"] { twoPass = v.pythonTruthy }
        if let v = extra["enable_asr_threepass"] { threePass = v.pythonTruthy }
    }
}

/// Inline mock transport: every `send` is answered synchronously through `onMessage`.
public final class MockTransport: ASRTransport {
    public let remote: MockASRRemote
    public var onMessage: (([UInt8]) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public private(set) var sent: [[UInt8]] = []
    public private(set) var sentRequests: [WebSocketRequest] = []
    public private(set) var bytesSent = 0
    public private(set) var bytesReceived = 0
    /// Tests can disable request retention for throughput benchmarks.
    public var retainSent = true
    /// Optional artificial delivery hook (e.g. dispatch asynchronously) — defaults to inline.
    public var deliver: (([UInt8], @escaping ([UInt8]) -> Void) -> Void)? = nil

    public init(remote: MockASRRemote = MockASRRemote()) { self.remote = remote }

    public func open(completion: @escaping (Error?) -> Void) { completion(nil) }

    public func send(_ data: [UInt8]) throws {
        bytesSent += data.count
        let request = try WebSocketRequest.decode(data)
        if retainSent {
            sent.append(data)
            sentRequests.append(request)
        }
        for response in remote.handle(request) {
            let bytes = response.encode()
            bytesReceived += bytes.count
            if let deliver = deliver {
                deliver(bytes) { [weak self] b in self?.onMessage?(b) }
            } else {
                onMessage?(bytes)
            }
        }
    }

    public func close() {}
}

public func lastFinishAudio(_ transport: MockTransport) -> Bool {
    guard let last = lastTaskRequest(transport.sentRequests) else { return false }
    return finishAudioFlag(last)
}
