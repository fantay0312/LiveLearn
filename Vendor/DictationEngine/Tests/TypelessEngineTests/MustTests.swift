// ENGINE_REBUILD_SPEC §28.1 MUST tests, ported from the Python tests/test_must_28_1.py and
// tests/test_cometix_compat.py against the Swift implementation.
import Foundation
import XCTest
@testable import TypelessCore

final class ScriptedTransport: ASRTransport {
    var onMessage: (([UInt8]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var bytesSent = 0
    var bytesReceived = 0
    var replies: [[UInt8]]
    var sent: [[UInt8]] = []
    init(_ replies: [[UInt8]]) { self.replies = replies }
    func open(completion: @escaping (Error?) -> Void) { completion(nil) }
    func send(_ data: [UInt8]) throws {
        sent.append(data)
        if !replies.isEmpty { onMessage?(replies.removeFirst()) }
    }
    func close() {}
}

final class WireTests: XCTestCase {
    func testVarintRoundTrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 300, 1 << 32, UInt64.max] {
            let encoded = encodeVarint(value)
            let (decoded, offset) = try decodeVarint(encoded)
            XCTAssertEqual(decoded, value)
            XCTAssertEqual(offset, encoded.count)
        }
    }

    func testVarintTruncated() {
        XCTAssertThrowsError(try decodeVarint([0x80])) { XCTAssertEqual($0 as? WireError, .varintTruncated) }
        XCTAssertThrowsError(try decodeVarint([])) { XCTAssertEqual($0 as? WireError, .varintTruncated) }
    }

    func testVarintTooLong() {
        XCTAssertThrowsError(try decodeVarint([UInt8](repeating: 0x80, count: 10))) { XCTAssertEqual($0 as? WireError, .varintTooLong) }
    }

    func testFieldNumberZero() {
        XCTAssertThrowsError(try ProtoReader.fields(encodeVarint(0))) { XCTAssertEqual($0 as? WireError, .fieldNumberZero) }
    }

    func testUnsupportedWireType() {
        XCTAssertThrowsError(try ProtoReader.fields(encodeVarint((1 << 3) | 3) + [0])) { XCTAssertEqual($0 as? WireError, .unsupportedWireType(3)) }
    }

    func testLengthExceedsBufferAndFixedTruncated() {
        XCTAssertThrowsError(try ProtoReader.fields([0x0A, 0x05, 0x01])) { XCTAssertEqual($0 as? WireError, .lengthExceedsBuffer) }
        XCTAssertThrowsError(try ProtoReader.fields([0x09, 0x01, 0x02])) { XCTAssertEqual($0 as? WireError, .fixed64Truncated) }
        XCTAssertThrowsError(try ProtoReader.fields([0x0D, 0x01])) { XCTAssertEqual($0 as? WireError, .fixed32Truncated) }
        // fixed32/fixed64 are parsed and preserved
        let fields = try? ProtoReader.fields([0x0D, 1, 2, 3, 4, 0x11, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(fields?.map { $0.type }, [.fixed32, .fixed64])
    }
}

final class EnvelopeTests: XCTestCase {
    func testRequestFieldNumbersAndOmitZeros() throws {
        let req = WebSocketRequest(token: "t", appkey: "k", namespace: "ASR", event: "StartTask", taskId: "TASK", seqId: 0)
        XCTAssertEqual(try ProtoReader.fields(req.encode()).map { $0.number }, [1, 2, 3, 5, 8])
    }

    func testRequestResponseRoundTrip() throws {
        let req = WebSocketRequest(token: "tok", appkey: "key", namespace: "ASR", event: "TaskRequest",
                                   payload: Array("{\"timestamp_ms\":1}".utf8), data: [0xBB, 0x42, 0x01] + [UInt8](repeating: 0, count: 317),
                                   taskId: "ABC", seqId: 3, sessionId: "s1")
        XCTAssertEqual(try WebSocketRequest.decode(req.encode()), req)
        let resp = WebSocketResponse(taskId: "ABC", namespace: "ASR", event: "ASRResponse", statusCode: 20000000,
                                     payload: Array("{\"results\":[]}".utf8), seqId: 3, sessionId: "s1", requestId: "r1")
        XCTAssertEqual(try WebSocketResponse.decode(resp.encode()), resp)
        XCTAssertEqual(try ProtoReader.fields(resp.encode()).map { $0.number }, [1, 3, 4, 5, 7, 9, 10, 11])
    }

    func testUnknownFieldsSkippedAndTypeMismatchRejected() throws {
        var w = ProtoWriter()
        w.writeStringField(5, "StartTask")
        w.writeVarintField(99, 7) // unknown field
        w.writeStringField(8, "T")
        let req = try WebSocketRequest.decode(w.bytes)
        XCTAssertEqual(req.event, "StartTask")
        XCTAssertEqual(req.taskId, "T")
        var bad = ProtoWriter()
        bad.writeVarintField(5, 1) // event must be length-delimited
        XCTAssertThrowsError(try WebSocketRequest.decode(bad.bytes))
    }

    func testDumpProtoRedactsSecrets() throws {
        let req = WebSocketRequest(token: "SECRETTOKENVALUE", appkey: "SECRETAPPKEY", namespace: "ASR", event: "StartTask", taskId: "TASK")
        let dumped = try dumpProto(req.encode())
        XCTAssertTrue(dumped.contains("kind=WebSocketRequest"))
        XCTAssertTrue(dumped.contains("field=1 name=token wire=2 <redacted len=16 sha256_12="))
        XCTAssertTrue(dumped.contains("field=2 name=appkey wire=2 <redacted len=12 sha256_12="))
        XCTAssertTrue(dumped.contains("field=5 name=event wire=2 string 'StartTask'"))
        XCTAssertFalse(dumped.contains("SECRETTOKENVALUE"))
        XCTAssertFalse(dumped.contains("SECRETAPPKEY"))
    }

    func testDumpProtoRedactsJSONKeysAndPEM() throws {
        let payload = Array("{\"extra\":{\"device_id\":\"1234567890\",\"aid\":\"685343\"}}".utf8)
        let req = WebSocketRequest(namespace: "ASR", event: "StartSession", payload: payload, taskId: "T")
        let dumped = try dumpProto(req.encode())
        XCTAssertTrue(dumped.contains("json {\"extra\":{\"device_id\":\"<redacted>\",\"aid\":\"685343\"}}"), dumped)
        XCTAssertFalse(dumped.contains("1234567890"))
        let pem = WebSocketResponse(event: "X", payload: Array("-----BEGIN PRIVATE KEY-----abc".utf8), requestId: "r")
        let d2 = try dumpProto(pem.encode())
        XCTAssertTrue(d2.contains("kind=WebSocketResponse"))
        XCTAssertTrue(d2.contains("<redacted len=30"))
        XCTAssertFalse(d2.contains("PRIVATE KEY"))
        let long = WebSocketResponse(event: String(repeating: "x", count: 130), requestId: "r")
        XCTAssertTrue(try dumpProto(long.encode()).contains("string len=130 sha256_12="))
    }
}

final class JSONTests: XCTestCase {
    func testPythonCompatibleCompactSerialization() throws {
        var tenth = 0.1
        tenth += 0.2 // 0.30000000000000004 in both IEEE-754 Python and Swift
        let value = JSONValue.obj([
            ("b", .bool(true)), ("a", .int(1)), ("f", .double(tenth)), ("z", .double(0.0)), ("e", .double(1e16)), ("s", .string("中文\"\n\u{1}")),
            ("n", .null), ("arr", .array([.double(1.2), .int(-3)])),
        ])
        XCTAssertEqual(value.compactJSON(), "{\"b\":true,\"a\":1,\"f\":0.30000000000000004,\"z\":0.0,\"e\":1e+16,\"s\":\"中文\\\"\\n\\u0001\",\"n\":null,\"arr\":[1.2,-3]}")
        XCTAssertEqual(pythonFloatRepr(0.2), "0.2")
        XCTAssertEqual(pythonFloatRepr(2), "2.0")
        XCTAssertEqual(pythonFloatRepr(0.00001), "1e-05")
        XCTAssertEqual(pythonFloatRepr(0.0001), "0.0001")
    }

    func testParseRoundTripAndOrder() throws {
        let text = "{\"results\":[{\"text\":\"测试1\",\"is_interim\":true,\"start_time\":0.0,\"end_time\":1.2,\"extra\":{\"seq_id\":20}}],\"extra\":{\"seq_id\":20},\"u\":\"\\ud83d\\ude00\\u4e2d\"}"
        let parsed = try JSONParser.parse(text)
        XCTAssertEqual(parsed["results"]?.arrayValue?.first?["end_time"], .double(1.2))
        XCTAssertEqual(parsed["extra"]?["seq_id"], .int(20))
        XCTAssertEqual(parsed["u"], .string("😀中"))
        XCTAssertEqual(parsed.objectValue?.keys, ["results", "extra", "u"])
        XCTAssertThrowsError(try JSONParser.parse("{\"a\":}"))
        XCTAssertThrowsError(try JSONParser.parse("[1,2"))
        XCTAssertEqual(try JSONParser.parse("{\"a\":1,\"a\":2}"), .obj([("a", .int(2))]))
    }
}

final class OpusTests: XCTestCase {
    func test20ms159And40ms320bb4201() throws {
        let encoder = try SpeechOpusEncoder()
        let frame20 = try encoder.encode20ms([UInt8](repeating: 0, count: 640))
        XCTAssertEqual(frame20.count, opusCBRFrameBytes)
        let packet = try encoder.encode40ms([UInt8](repeating: 0, count: frameBytes))
        XCTAssertEqual(packet.count, speechOpusPacketBytes)
        XCTAssertEqual(Array(packet[0..<3]), speechOpusPrefix)
    }

    func testPackRejectsWrongSizesAndMismatchedTOC() {
        XCTAssertThrowsError(try packSpeechOpus(first: [UInt8](repeating: 0, count: 100), second: [UInt8](repeating: 0, count: 159)))
        var a = [UInt8](repeating: 0, count: 159); a[0] = 0xB8
        var b = [UInt8](repeating: 0, count: 159); b[0] = 0xF8
        XCTAssertThrowsError(try packSpeechOpus(first: a, second: b))
    }

    func testStreamingHalvesMatchWholeFrame() throws {
        let pcm = syntheticPCM(frames: 10)
        let whole = try SpeechOpusEncoder()
        let halves = try SpeechOpusEncoder()
        var packet = [UInt8](repeating: 0, count: speechOpusPacketBytes)
        try pcm.withUnsafeBytes { raw in
            for i in 0..<10 {
                let frame = UnsafeRawBufferPointer(rebasing: raw[i * frameBytes..<(i + 1) * frameBytes])
                let expected = try whole.encode40ms(Array(frame))
                let done1 = try packet.withUnsafeMutableBytes { try halves.pushHalf(UnsafeRawBufferPointer(rebasing: frame[0..<640]), into: $0) }
                XCTAssertFalse(done1)
                let done2 = try packet.withUnsafeMutableBytes { try halves.pushHalf(UnsafeRawBufferPointer(rebasing: frame[640..<1280]), into: $0) }
                XCTAssertTrue(done2)
                XCTAssertEqual(packet, expected)
            }
        }
    }

    func testEncodePCMPadOnlyOnFinish() throws {
        let encoder = try SpeechOpusEncoder()
        XCTAssertThrowsError(try encoder.encodePCM([UInt8](repeating: 0, count: 1300), pad: false))
        XCTAssertEqual(try encoder.encodePCM([UInt8](repeating: 0, count: 1300), pad: true).count, 2)
        XCTAssertEqual(try encoder.encodePCM([], pad: true).count, 1)
    }

    /// Same libopus + same parameters ⇒ deterministic bytes: compare with the Python tool.
    func testByteIdenticalWithPythonEncoder() throws {
        let pythonTree = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("typeless-engine")
        let python = "/opt/homebrew/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: pythonTree.appendingPathComponent("src/typeless_engine/opus.py").path) else {
            throw XCTSkip("python tree or python3 not available")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("typeless-opus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("in.wav").path
        try writeWAV(path: wav, pcm: syntheticPCM(frames: 60) + [UInt8](repeating: 0x10, count: 500))
        let pyOut = tmp.appendingPathComponent("py.bin").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-m", "typeless_engine", "encode-opus", wav, "--output", pyOut]
        proc.currentDirectoryURL = pythonTree
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = pythonTree.appendingPathComponent("src").path
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw XCTSkip("python encode-opus failed (\(proc.terminationStatus))") }
        let swOut = tmp.appendingPathComponent("sw.bin").path
        let count = try encodeWAVFile(input: wav, output: swOut)
        XCTAssertEqual(count, 61)
        XCTAssertEqual(try readFile(path: pyOut), try readFile(path: swOut))
    }
}

final class TranscriptTests: XCTestCase {
    func testTwoPassPicksLastRevision() {
        let event = normalizePayload(.obj([("results", .array([
            .obj([("text", .string("扣德克斯")), ("is_interim", .bool(true))]),
            .obj([("text", .string("Codex")), ("is_interim", .bool(true))]),
        ]))]))
        XCTAssertEqual(event?.text, "Codex")
        XCTAssertEqual(event?.resultCount, 2)
        XCTAssertEqual(event?.isFinal, false)
    }

    func testTwoPassPicksLastFinal() {
        let event = normalizePayload(.obj([("results", .array([
            .obj([("text", .string("first")), ("is_interim", .bool(false))]),
            .obj([("text", .string("second")), ("is_interim", .bool(false))]),
            .string("ignore-me"),
        ]))]))
        XCTAssertEqual(event?.text, "second")
        XCTAssertEqual(event?.isFinal, true)
        XCTAssertEqual(event?.resultCount, 2)
    }

    func testEmptyTextRequiresVadStart() {
        XCTAssertNil(normalizePayload(.obj([("results", .array([.obj([("text", .string("")), ("is_interim", .bool(true))])]))])))
        let event = normalizePayload(.obj([("results", .array([
            .obj([("text", .string("")), ("is_interim", .bool(true)), ("extra", .obj([("vad_start", .int(1))]))]),
        ]))]))
        XCTAssertEqual(event?.text, "")
    }

    func testSeqPriorityAndBytesPayload() throws {
        let raw = Array("{\"results\":[{\"text\":\"a\",\"is_interim\":true,\"extra\":{\"seq_id\":\"7\"}}],\"extra\":{\"seq_id\":9}}".utf8)
        XCTAssertEqual(try normalizePayload(raw, envelopeSeq: 3)?.seqId, 7)
        let raw2 = Array("{\"results\":[{\"text\":\"a\",\"is_interim\":true}],\"extra\":{\"seq_id\":9}}".utf8)
        XCTAssertEqual(try normalizePayload(raw2, envelopeSeq: 3)?.seqId, 9)
        let raw3 = Array("{\"results\":[{\"text\":\"a\",\"is_interim\":true}]}".utf8)
        XCTAssertEqual(try normalizePayload(raw3, envelopeSeq: 3)?.seqId, 3)
        XCTAssertNil(try normalizePayload([], envelopeSeq: 1))
        XCTAssertNil(try normalizePayload(Array("   ".utf8), envelopeSeq: 1))
        XCTAssertThrowsError(try normalizePayload(Array("{bad".utf8)))
    }

    func testVadDedupKey() {
        var timeline = TranscriptTimeline()
        timeline.update(TranscriptEvent(text: "hi", isFinal: true, startTime: 0, endTime: 1))
        timeline.update(TranscriptEvent(text: "hi", isFinal: true, startTime: 0, endTime: 1))
        XCTAssertEqual(timeline.text, "hi")
        timeline.update(TranscriptEvent(text: "hello", isFinal: true, startTime: 0, endTime: 1.2))
        XCTAssertEqual(timeline.text, "hello")
        timeline.update(TranscriptEvent(text: "hihello world", isFinal: true, startTime: 0, endTime: 2))
        XCTAssertEqual(timeline.text, "hihello world")
    }

    func testInterimSuffixAfterCommitted() {
        var timeline = TranscriptTimeline()
        timeline.update(TranscriptEvent(text: "你好", isFinal: true, startTime: 0, endTime: 1))
        timeline.update(TranscriptEvent(text: "你好世界", isFinal: false, startTime: 0, endTime: 2))
        XCTAssertEqual(timeline.text, "你好世界")
        XCTAssertEqual(timeline.currentHypothesis, "世界")
    }

    func testSameAudioRangeRevisesInsteadOfAppendingAndPreservesEarlierSentence() {
        var timeline = TranscriptTimeline()
        timeline.update(TranscriptEvent(text: "请使用", isFinal: true, startTime: 0, endTime: 1))
        timeline.update(TranscriptEvent(text: "扣德克斯", isFinal: true, startTime: 1, endTime: 2))
        timeline.update(TranscriptEvent(text: "Codex", isFinal: false, startTime: 1, endTime: 2.1))
        XCTAssertEqual(timeline.text, "请使用Codex")
        timeline.update(TranscriptEvent(text: "Codex。", isFinal: true, startTime: 1, endTime: 2.2))
        XCTAssertEqual(timeline.text, "请使用Codex。")
    }

    func testSessionFinalGate() {
        var gate = SessionFinalGate()
        XCTAssertFalse(gate.canEmit())
        gate.markLocalFinish()
        XCTAssertFalse(gate.canEmit())
        gate.markRemoteFinished()
        XCTAssertTrue(gate.canEmit())
        gate.markSent()
        XCTAssertFalse(gate.canEmit())
    }

    func testCandidateGroupsAndPassName() {
        XCTAssertEqual(passName(1), "one")
        XCTAssertEqual(passName(2), "two")
        XCTAssertEqual(passName(5), "three")
        let groups = candidateGroups(.obj([("results", .array([
            .obj([("text", .string("a")), ("start_time", .double(1.0)), ("end_time", .double(0.5)), ("extra", .obj([("seq_id", .int(4))]))]),
            .string("skip"),
        ]))]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["end_time"], .double(1.0))
        XCTAssertEqual(groups[0]["seq_id"], .int(4))
        XCTAssertEqual(groups[0]["nbest"], .array([]))
    }
}

final class PendingAndSessionTests: XCTestCase {
    func testPendingLastPacketFinishAudio() {
        var buf = PendingPacketBuffer()
        XCTAssertNil(buf.push([UInt8](repeating: 0x41, count: 320)))
        let first = buf.push([UInt8](repeating: 0x42, count: 320))
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.finishAudio, false)
        XCTAssertEqual(first?.seqId, 1)
        let last = buf.finish()
        XCTAssertTrue(last.finishAudio)
        XCTAssertEqual(last.seqId, 2)
        XCTAssertEqual(last.data, [UInt8](repeating: 0x42, count: 320))
    }

    func testEmptySessionStillSendsFinishAudio() {
        var buf = PendingPacketBuffer()
        let last = buf.finish()
        XCTAssertTrue(last.finishAudio)
        XCTAssertEqual(last.data, [])
        XCTAssertEqual(last.seqId, 1)
        XCTAssertEqual(String(decoding: last.metadata(), as: UTF8.self), "{\"timestamp_ms\":0,\"extra\":{\"finish_audio\":true}}")
    }

    func testMockStateOrderAndFinishAudio() throws {
        let transport = MockTransport()
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, clock: { 1000 }, idFactory: { "TASK-1" })
        var started = 0, finished = 0
        session.onStarted = { started += 1 }
        session.onFinished = { finished += 1 }
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "dev", appId: "685343"))
        XCTAssertEqual(session.state, .streaming)
        try session.pushPacket([UInt8](repeating: 0x11, count: 320))
        try session.pushPacket([UInt8](repeating: 0x22, count: 320))
        try session.finish()
        let events = transport.sentRequests.map { $0.event }
        XCTAssertEqual(Array(events.prefix(2)), ["StartTask", "StartSession"])
        XCTAssertEqual(events.last, "FinishSession")
        let tasks = transport.sentRequests.filter { $0.event == "TaskRequest" }
        XCTAssertEqual(tasks.map { $0.seqId }, [1, 2])
        XCTAssertFalse(finishAudioFlag(tasks[0]))
        XCTAssertTrue(finishAudioFlag(tasks[1]))
        XCTAssertEqual(tasks[1].data, [UInt8](repeating: 0x22, count: 320))
        XCTAssertEqual(String(decoding: tasks[0].payload, as: UTF8.self), "{\"timestamp_ms\":1000}")
        XCTAssertTrue(tasks.allSatisfy { $0.appkey.isEmpty && $0.taskId == "TASK-1" && $0.namespace == "ASR" })
        XCTAssertTrue(transport.sentRequests.filter { $0.event != "TaskRequest" }.allSatisfy { $0.appkey == "k" })
        XCTAssertTrue(session.remoteSessionFinished)
        XCTAssertEqual(session.transcripts.last?.text, mockFinalText)
        XCTAssertEqual(session.state, .closed)
        XCTAssertEqual(started, 1)
        XCTAssertEqual(finished, 1)
    }

    func testEagerModeSendsImmediatelyAndEmptyFinish() throws {
        let transport = MockTransport()
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, finishMode: .eager)
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "dev", appId: "685343"))
        try session.pushPacket([UInt8](repeating: 0x11, count: 320))
        XCTAssertEqual(transport.sentRequests.filter { $0.event == "TaskRequest" }.count, 1)
        try session.finish()
        let tasks = transport.sentRequests.filter { $0.event == "TaskRequest" }
        XCTAssertEqual(tasks.map { $0.seqId }, [1, 2])
        XCTAssertFalse(finishAudioFlag(tasks[0]))
        XCTAssertTrue(finishAudioFlag(tasks[1]))
        XCTAssertEqual(tasks[1].data, [])
    }

    func testUnexpectedEventAborts() throws {
        let transport = ScriptedTransport([WebSocketResponse(event: "NopeEvent", statusCode: 0).encode()])
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, idFactory: { "T" })
        var error: ASRSessionError? = nil
        session.onError = { error = $0 }
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "d", appId: "1"))
        XCTAssertEqual(session.state, .failed)
        XCTAssertTrue(error?.message.contains("NopeEvent") == true, error?.message ?? "")
    }

    func testTaskFailedAndTextPongPassthrough() throws {
        let transport = ScriptedTransport([
            Array("pong".utf8),
            WebSocketResponse(event: "TaskFailed", statusCode: 3003, statusText: "bad key").encode(),
        ])
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, idFactory: { "T" })
        var error: ASRSessionError? = nil
        session.onError = { error = $0 }
        try session.start(sessionPayload: [])
        XCTAssertEqual(session.events.first?.event, "Pong")
        XCTAssertEqual(session.state, .waitTaskStarted) // pong is passthrough
        transport.onMessage?(transport.replies.removeFirst())
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(error?.message, "remote failed event=TaskFailed status=3003 text=bad key")
    }

    func testWrongMockOrderFails() {
        let remote = MockASRRemote()
        let replies = remote.handle(WebSocketRequest(appkey: "k", namespace: "ASR", event: "FinishSession", taskId: "X"))
        XCTAssertEqual(replies.first?.event, "SessionFailed")
        XCTAssertEqual(replies.first?.statusCode, 1)
    }

    func testMockPassCountFollowsStartSession() throws {
        let transport = MockTransport()
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport)
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "d", appId: "1", twoPass: true, threePass: true))
        try session.pushPacket([UInt8](repeating: 0, count: 320))
        try session.pushPacket([UInt8](repeating: 0, count: 320))
        XCTAssertEqual(session.transcripts.first?.resultCount, 3)
        XCTAssertEqual(session.transcripts.first?.text, mockFinalText)
        try session.finish()
        XCTAssertEqual(session.transcripts.last?.isFinal, true)
    }
}

final class ContextTests: XCTestCase {
    func testContextIsCompactJSONThenStandardBase64() throws {
        let context = buildChatContext(text: "光标附近文档", cursor: 6, hostId: "EDITOR", hotwords: [])
        let payload = try JSONParser.parse(buildStartSessionPayload(deviceId: "DEVICE", appId: "685343", context: context))
        let encoded = try XCTUnwrap(payload["extra"]?["context"]?.stringValue)
        let raw = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertFalse(raw.contains(0x20))
        XCTAssertFalse(raw.contains(0x0A))
        let decoded = try JSONParser.parse([UInt8](raw))
        XCTAssertEqual(decoded["chatContext"]?["hostID"], .string("EDITOR"))
        XCTAssertNil(decoded["hotwordsInfo"]) // empty array pruned
        XCTAssertEqual(encodeContextB64(context), encoded)
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "{\"chatContext\":{\"data\":[{\"cursorPosition\":6,\"text\":\"光标附近文档\"}],\"hostID\":\"EDITOR\"}}")
    }

    func testStartSessionShapeMatchesSpec() throws {
        let bytes = buildStartSessionPayload(deviceId: "DEVICE", appId: "685343", twoPass: true, threePass: false)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"audio_info\":{\"format\":\"speech_opus\",\"sample_rate\":16000,\"channel\":1},\"enable_punctuation\":true,\"enable_speech_rejection\":false,\"extra\":{\"aid\":\"685343\",\"device_id\":\"DEVICE\",\"did\":\"DEVICE\",\"enable_text_filter\":true,\"remove_space_between_han_num\":true,\"remove_space_between_han_eng\":true,\"asr_params\":{\"enable_global_tracking\":true}"), text)
        XCTAssertTrue(text.hasSuffix("\"enable_asr_twopass\":true,\"enable_asr_threepass\":false}}"), text)
    }
}

final class TypelessTests: XCTestCase {
    func testLongestSourceFirstNonCascade() throws {
        let rules = [Replacement("扣德克斯", "Codex"), Replacement("Codex", "其他值")]
        XCTAssertEqual(try applyReplacements("扣德克斯", rules), "Codex")
        let doc = TypelessDocument("")
        try doc.addReplacement("扣德克斯", "Codex")
        try doc.addReplacement("Codex", "其他值")
        XCTAssertEqual(try doc.replace("扣德克斯"), "Codex")
    }

    func testLaterSameSourceWinsAndEmptyTargetDeletes() throws {
        let rules = [Replacement("foo", "one"), Replacement("foo", "two"), Replacement("bar", "")]
        XCTAssertEqual(try applyReplacements("foo bar", rules), "two ")
    }

    func testEmptySourceIllegal() {
        XCTAssertThrowsError(try applyReplacements("x", [Replacement("", "y")]))
        XCTAssertThrowsError(try parseReplacements(.array([.obj([("source", .string("")), ("target", .string("y"))])])))
    }

    func testCursorWindow8020AndRedistribute() {
        let text = String(repeating: "a", count: 1000) + "X" + String(repeating: "b", count: 1000)
        let window = cursorWindow(text, 1000, limit: 100)
        XCTAssertEqual(window.cursor, 80)
        XCTAssertEqual(window.text, String(Array(text)[920..<1020]))
        let full = cursorWindow("hello", 2, limit: 100)
        XCTAssertEqual(full.text, "hello")
        XCTAssertEqual(full.cursor, 2)
        let nearStart = cursorWindow(text, 5, limit: 100)
        XCTAssertEqual(nearStart.start, 0)
        XCTAssertEqual(nearStart.text.count, 100)
        let nearEnd = cursorWindow(text, 1998, limit: 100)
        XCTAssertEqual(nearEnd.end, 2001)
        XCTAssertEqual(nearEnd.text.count, 100)
        XCTAssertEqual(nearEnd.cursor, 97)
    }

    func testPreviewDoesNotMoveCursorCommitDoes() throws {
        let doc = TypelessDocument("已有文档", cursorPosition: 4)
        XCTAssertEqual(try doc.preview("口述"), "已有文档口述")
        XCTAssertEqual(doc.cursorPosition, 4)
        XCTAssertEqual(try doc.commit("口述"), "口述")
        XCTAssertEqual(doc.text, "已有文档口述")
        XCTAssertEqual(doc.cursorPosition, 6)
    }

    func testHotwordMergeFromNonEmptyTargets() throws {
        let doc = TypelessDocument("")
        try doc.addReplacement("扣德克斯", "Codex", frequency: 10)
        try doc.addReplacement("删掉", "")
        XCTAssertEqual(doc.hotwordsFromReplacements(), [Hotword("Codex", 10)])
        let merged = mergeHotwords([Hotword("Codex", 3), Hotword("A", 1)], doc.hotwordsFromReplacements())
        XCTAssertEqual(merged, [Hotword("Codex", 10), Hotword("A", 1)])
    }

    func testBoundedUserEditLearning() {
        let learned = learnUserEdit(original: "使用扣德克斯", revised: "使用Codex")
        XCTAssertEqual(learned?.source, "扣德克斯")
        XCTAssertEqual(learned?.target, "Codex")
        XCTAssertNil(learnUserEdit(original: "hello", revised: "hello!"))
        XCTAssertNil(learnUserEdit(original: String(repeating: "a", count: 70), revised: String(repeating: "b", count: 70)))
        XCTAssertNil(learnUserEdit(original: "keep", revised: "keep extra"))
    }

    func testParseHotwordsShapes() throws {
        let words = try parseHotwords(.array([.string("专有名词"), .obj([("word", .string("Typeless")), ("frequency", .int(10))]), .obj([("text", .string("T2"))]), .int(5)]))
        XCTAssertEqual(words, [Hotword("专有名词", 8), Hotword("Typeless", 10), Hotword("T2", 8)])
        XCTAssertEqual(try parseHotwords(.obj([("w", .int(3)), ("", .int(1))])), [Hotword("w", 3)])
        XCTAssertThrowsError(try parseHotwords(.string("x")))
    }
}

final class PcmSplitTests: XCTestCase {
    func test6400BytesFiveFrames() throws {
        var framer = PCMFramer()
        let frames = try framer.takeFrames(incoming: [UInt8](repeating: 0, count: 6400), finish: false)
        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { $0.count == frameBytes })
        XCTAssertEqual(framer.pendingBytes, 0)
    }

    func testOddChunkingAndPadOnlyOnFinish() throws {
        var framer = PCMFramer()
        var total = 0
        for chunk in [2, 1000, 1278, 2, 500] {
            total += try framer.takeFrames(incoming: [UInt8](repeating: 1, count: chunk), finish: false).count
        }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(framer.pendingBytes, 2782 - 2560)
        let tail = try framer.takeFrames(finish: true)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0].count, frameBytes)
        XCTAssertEqual(Array(tail[0][222...]), [UInt8](repeating: 0, count: frameBytes - 222))
        XCTAssertThrowsError(try framer.append([1]))
    }
}

final class CometixTests: XCTestCase {
    func testAudioFormatMatchesProbeExceptBitrate() {
        let fmt = audioFormat().objectValue!
        let probe = cometixAudioFormatProbe().objectValue!
        XCTAssertEqual(fmt["sampleRate"], .int(16000))
        XCTAssertEqual(fmt["frameSamples"], .int(640))
        XCTAssertEqual(fmt["frameBytes"], .int(1280))
        XCTAssertEqual(fmt["encoding"], .string("linear16"))
        XCTAssertEqual(fmt["opusBitrate"], .int(63600))
        XCTAssertEqual(probe["opusBitrate"], .int(64000))
    }

    func testParseSessionConfigAndDidFile() throws {
        let parsed = try parseSessionConfig("{\"did\":\"DID123\",\"appKey\":\"KEY\",\"appId\":\"685343\",\"wssUrl\":\"wss://example.test/ws\",\"mode\":\"mock\",\"inputMode\":\"audio\",\"iid\":\"IID\",\"extra\":{\"x\":1}}")
        XCTAssertEqual(parsed["device_id"], .string("DID123"))
        XCTAssertEqual(parsed["app_key"], .string("KEY"))
        XCTAssertEqual(parsed["url"], .string("wss://example.test/ws"))
        XCTAssertEqual(parsed["mode"], .string("mock"))
        XCTAssertEqual(parsed["input_mode"], .string("audio"))
        XCTAssertEqual(parsed["start_session_extra"], .obj([("x", .int(1))]))
        XCTAssertEqual(try parseSessionConfig(""), [:])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("did-\(UUID().uuidString).json").path
        try writeFile(path: tmp, bytes: Array("{\"did\":\"FROMFILE\",\"iid\":\"I1\"}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertEqual(try loadDidFile(path: tmp), ["device_id": "FROMFILE", "iid": "I1"])
    }

    func testEnvAliases() throws {
        XCTAssertEqual(envAliases(["COMETIX_DEVICE_ID": "ENV-DID", "COMETIX_IID": "ENV-IID"]), ["device_id": "ENV-DID", "iid": "ENV-IID"])
        let profile = try loadProfile(env: ["COMETIX_DID": "DID-ONLY"], useSessionFile: false)
        XCTAssertEqual(profile.deviceId, "DID-ONLY")
    }

    func testSpecAndCometixExtras() throws {
        let extra = try XCTUnwrap(JSONParser.parse(buildStartSessionPayload(deviceId: "DEVICE", appId: "685343"))["extra"]?.objectValue)
        XCTAssertEqual(extra["aid"], .string("685343"))
        XCTAssertEqual(extra["did"], .string("DEVICE"))
        XCTAssertEqual(extra["enable_asr_twopass"], .bool(true))
        XCTAssertEqual(extra["enable_asr_threepass"], .bool(false))
        XCTAssertEqual(extra["asr_params"], .obj([("enable_global_tracking", .bool(true))]))
        XCTAssertEqual(extra["2a_send_commands"], .array([.string("帮我发送")]))
        XCTAssertEqual(extra["2a_send_enable"], .bool(true))
        XCTAssertEqual(extra["use_twopass_retry"], .bool(true))
        XCTAssertEqual(extra["enable_print_chinese"], .bool(true))
        XCTAssertNil(extra["context"])
        let overlay = try XCTUnwrap(JSONParser.parse(buildStartSessionPayload(deviceId: "D", appId: "1", inputMode: "audio", iid: "I", extraOverlay: JSONObject([("aid", .string("9")), ("custom", .int(1))])))["extra"]?.objectValue)
        XCTAssertEqual(overlay["aid"], .string("9"))
        XCTAssertEqual(overlay["input_mode"], .string("audio"))
        XCTAssertEqual(overlay["iid"], .string("I"))
        XCTAssertEqual(overlay["custom"], .int(1))
        XCTAssertEqual(overlay.keys.first, "aid")
    }

    func testTranscriptStagesAndSessionEvents() throws {
        let interim = TranscriptEvent(text: "hello", isFinal: false, resultCount: 1)
        let ev = transcriptToCometix(interim).objectValue!
        XCTAssertEqual(ev["type"], .string("transcript"))
        XCTAssertEqual(ev["stage"], .string("interim"))
        XCTAssertEqual(ev["is_interim"], .bool(true))
        let stable = TranscriptEvent(text: "hello.", isFinal: true, vadFinished: true, resultCount: 1)
        XCTAssertEqual(transcriptToCometix(stable)["stage"], .string("stable"))
        let fin = transcriptToCometix(stable, sessionFinal: true)
        XCTAssertEqual(fin["stage"], .string("session_final"))
        XCTAssertEqual(fin["stable_text"], .string("hello."))
        let transport = MockTransport()
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, clock: { 1 }, idFactory: { "SID" })
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "d", appId: "685343"))
        try session.pushPacket([UInt8](repeating: 0, count: 320))
        try session.finish()
        let events = sessionToCometixEvents(taskId: session.taskId, transcripts: session.transcripts, remoteFinished: session.remoteSessionFinished, mode: "mock")
        XCTAssertEqual(events.first?["type"], .string("ready"))
        XCTAssertEqual(events.first?["session_id"], .string("SID"))
        XCTAssertEqual(events.last?["type"], .string("close"))
        XCTAssertEqual(events[events.count - 2]["stage"], .string("session_final"))
    }
}

final class AdapterMustTests: XCTestCase {
    func testHealthShape() {
        let body = healthPayload()
        XCTAssertEqual(body["ok"], .bool(true))
        XCTAssertEqual(body["api_version"], .string("1"))
        XCTAssertEqual(body["capabilities"], .array([.string("asr"), .string("interim"), .string("correction")]))
        let blob = body.compactJSON()
        XCTAssertFalse(blob.contains("token") || blob.contains("appkey") || blob.contains("device_id"))
        XCTAssertEqual(blob, "{\"ok\":true,\"api_version\":\"1\",\"capabilities\":[\"asr\",\"interim\",\"correction\"]}")
    }

    func testUniqueFinalAndFivePackets() throws {
        var events: [JSONValue] = []
        let conn = AdapterConnection(profile: ASRProfile(appKey: "k", deviceId: "dev")) { events.append($0) }
        defer { conn.close() }
        try conn.onStart(.obj([("type", .string("start")), ("app", .string("EDITOR"))]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"], .string("ready"))
        XCTAssertEqual(events[0]["mode"], .string("mock"))
        XCTAssertEqual(events[0]["audio"]?["frame_bytes"], .int(1280))
        XCTAssertEqual(events[0]["audio"]?["encoding"], .string("linear16"))
        try conn.onPCM([UInt8](repeating: 0, count: 6400))
        let midCount = events.count - 1
        try conn.onFinish()
        let types = events.map { $0["type"]?.stringValue ?? "" }
        XCTAssertTrue(types.contains("interim") || types.contains("correction"))
        XCTAssertEqual(types.filter { $0 == "final" }.count, 1)
        XCTAssertFalse(types.contains("error"))
        XCTAssertEqual(midCount, 4) // 5 packets, pending policy → 4 TaskRequests → 4 interim events
        let fin = events.last!
        XCTAssertEqual(fin["type"], .string("final"))
        XCTAssertEqual(fin["asr_finished"], .bool(true))
        XCTAssertEqual(fin["text"], .string(mockFinalText))
        XCTAssertEqual(fin["raw_text"], .string(mockFinalText))
        XCTAssertEqual(fin["stage"], .string("session_final"))
        XCTAssertEqual(fin["stable_text"], .string(mockFinalText))
        XCTAssertEqual(fin["document"], .string(mockFinalText))
        XCTAssertEqual(fin["next_cursor_position"], .int(6))
        XCTAssertEqual(conn.pcmFramesSent, 5)
        XCTAssertFalse(conn.gate.canEmit())
        XCTAssertEqual(events[1]["stage"], .string("interim"))
        XCTAssertEqual(events[1]["pass"], .string("two"))
        XCTAssertEqual(events[1]["type"], .string("correction")) // two-pass mock ⇒ correction
        for key in ["stage", "pass_count", "display", "is_interim", "is_vad_finished", "pass", "candidate_groups", "document_preview", "seq_id", "start_time", "end_time", "segment_final", "replacement_applied"] {
            XCTAssertNotNil(events[1][key], key)
        }
        // duplicate finish is a no-op; PCM after finish is rejected
        try conn.onFinish()
        XCTAssertEqual(events.filter { $0["type"] == .string("final") }.count, 1)
        XCTAssertThrowsError(try conn.onPCM([UInt8](repeating: 0, count: 1280)))
    }

    func testReplacementsPreviewDocumentAndOnePass() throws {
        var events: [JSONValue] = []
        let conn = AdapterConnection(profile: ASRProfile(appKey: "k")) { events.append($0) }
        defer { conn.close() }
        try conn.onStart(.obj([
            ("type", .string("start")), ("context", .string("已有文档")), ("cursor_position", .int(2)),
            ("replacements", .array([.obj([("source", .string("模拟")), ("target", .string("Mock"))])])),
            ("hotwords", .array([.string("Typeless")])), ("two_pass", .bool(false)),
        ]))
        try conn.onPCM([UInt8](repeating: 0, count: 2560))
        XCTAssertEqual(events[1]["type"], .string("interim")) // one-pass, not final
        XCTAssertEqual(events[1]["pass"], .string("one"))
        XCTAssertEqual(events[1]["text"], .string("Mock识别结果"))
        XCTAssertEqual(events[1]["raw_text"], .string(mockFinalText))
        XCTAssertEqual(events[1]["replacement_applied"], .bool(true))
        XCTAssertEqual(events[1]["document_preview"], .string("已有Mock识别结果文档"))
        XCTAssertEqual(events[1]["display"], .string("Mock识别结果"))
        try conn.onFinish()
        let fin = events.last!
        XCTAssertEqual(fin["document"], .string("已有Mock识别结果文档"))
        XCTAssertEqual(fin["next_cursor_position"], .int(2 + 8))
        XCTAssertEqual(fin["replacement_rules"], .array([.obj([("source", .string("模拟")), ("target", .string("Mock")), ("frequency", .int(8))])]))
        XCTAssertEqual(events[0]["typeless"]?["replacement_rules"], fin["replacement_rules"])
        // StartSession carried the hotwords (client + replacement target) in the context
        let engine = try XCTUnwrap(conn.engine)
        let transport = try XCTUnwrap(engine.transport as? MockTransport)
        let start = try XCTUnwrap(transport.sentRequests.first { $0.event == "StartSession" })
        let payload = try JSONParser.parse(start.payload)
        let ctx = try JSONParser.parse([UInt8](try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(payload["extra"]?["context"]?.stringValue)))))
        XCTAssertEqual(ctx["hotwordsInfo"], .array([.obj([("word", .string("Typeless")), ("frequency", .int(8))]), .obj([("word", .string("Mock")), ("frequency", .int(8))])]))
        XCTAssertEqual(ctx["chatContext"]?["data"]?.arrayValue?.first?["cursorPosition"], .int(2))
        XCTAssertEqual(payload["extra"]?["enable_asr_twopass"], .bool(false))
    }

    func testStartValidationAndErrorFrame() throws {
        var events: [JSONValue] = []
        let conn = AdapterConnection(profile: ASRProfile(appKey: "k")) { events.append($0) }
        XCTAssertThrowsError(try conn.onPCM([UInt8](repeating: 0, count: 1280))) {
            XCTAssertEqual(($0 as? AdapterError)?.code, "invalid_request")
        }
        XCTAssertThrowsError(try conn.onStart(.obj([("type", .string("nope"))])))
        XCTAssertThrowsError(try conn.onStart(.obj([("type", .string("start")), ("cursor_position", .string("x"))])))
        XCTAssertThrowsError(try conn.onStart(.array([])))
        let frame = errorFrame("boom", code: "asr_failed", retryable: false)
        XCTAssertEqual(frame.compactJSON(), "{\"type\":\"error\",\"error\":\"boom\",\"message\":\"boom\",\"code\":\"asr_failed\",\"retryable\":false}")
        conn.handleFailure("x")
        conn.handleFailure("y")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"], .string("error"))
    }

    func testParseStartFrameDefaults() throws {
        let start = try parseStartFrame(.obj([("type", .string("start")), ("context", .string("abc"))]))
        XCTAssertEqual(start["cursor_position"], .int(3))
        XCTAssertEqual(start["context_window_chars"], .int(2048))
        XCTAssertEqual(start["two_pass"], .bool(true))
        XCTAssertEqual(start["three_pass"], .bool(false))
        XCTAssertEqual(start["hotwords"], .array([]))
        XCTAssertEqual(start["app"], .string(""))
        let sized = try parseStartFrame(.obj([("type", .string("start")), ("context_window_chars", .int(-5)), ("two_pass", .string("yes"))]))
        XCTAssertEqual(sized["context_window_chars"], .int(2048))
        XCTAssertEqual(sized["two_pass"], .bool(true))
    }

    func testPCMBeforeReadyIsBufferedUntilSessionStarted() throws {
        // Deliver mock responses asynchronously to emulate a real network: PCM arriving before
        // SessionStarted must be buffered and flushed, not rejected.
        var events: [JSONValue] = []
        var pendingDeliveries: [([UInt8], ([UInt8]) -> Void)] = []
        let transport = MockTransport()
        transport.deliver = { bytes, cb in pendingDeliveries.append((bytes, cb)) }
        let conn = AdapterConnection(profile: ASRProfile(appKey: "k"), mode: "mock", engineFactory: {
            try CoreEngine(profile: ASRProfile(appKey: "k"), transport: transport)
        }) { events.append($0) }
        defer { conn.close() }
        try conn.onStart(.obj([("type", .string("start"))]))
        try conn.onPCM([UInt8](repeating: 0, count: 2560))
        XCTAssertEqual(conn.pcmFramesSent, 0)
        XCTAssertTrue(events.isEmpty)
        while !pendingDeliveries.isEmpty {
            let (bytes, cb) = pendingDeliveries.removeFirst()
            cb(bytes)
        }
        XCTAssertEqual(events.first?["type"], .string("ready"))
        XCTAssertEqual(conn.pcmFramesSent, 2)
        XCTAssertEqual(events.count, 2) // ready + one interim (pending policy)
    }
}

final class ConfigTests: XCTestCase {
    func testDefaultsAndPrecedence() throws {
        let defaults = try loadProfile(env: [:], useSessionFile: false)
        XCTAssertEqual(defaults.url, "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws")
        XCTAssertEqual(defaults.appId, "685343")
        XCTAssertEqual(defaults.appKey, "OrnqKvSSrs")
        XCTAssertEqual(defaults.deviceId, "7418239102837461")
        XCTAssertEqual(defaults.namespace, "ASR")
        XCTAssertEqual(defaults.protoVersion, "v2")
        XCTAssertEqual(defaults.token, "")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).json").path
        try writeFile(path: tmp, bytes: Array("{\"appkey\":\"FILEKEY\",\"deviceId\":\"FILEDID\",\"wssUrl\":\"wss://file/ws\",\"enable_asr_twopass\":false,\"X-SS-DP\":\"dp\"}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        chmod(tmp, 0o644)
        XCTAssertThrowsError(try loadProfile(env: ["TYPELESS_CONFIG": tmp], useSessionFile: false)) {
            XCTAssertTrue("\($0)".contains("mode 0600"))
        }
        chmod(tmp, 0o600)
        let fromFile = try loadProfile(env: ["TYPELESS_CONFIG": tmp], useSessionFile: false)
        XCTAssertEqual(fromFile.appKey, "FILEKEY")
        XCTAssertEqual(fromFile.deviceId, "FILEDID")
        XCTAssertEqual(fromFile.url, "wss://file/ws")
        XCTAssertEqual(fromFile.twoPass, false)
        XCTAssertEqual(fromFile.ssDp, "dp")
        let env = ["TYPELESS_CONFIG": tmp, "TYPELESS_ASR_APP_KEY": "ENVKEY", "TYPELESS_ASR_TOKEN": "ENVTOKEN", "COMETIX_IID": "IID1"]
        let fromEnv = try loadProfile(env: env, useSessionFile: false)
        XCTAssertEqual(fromEnv.appKey, "ENVKEY") // env beats file
        XCTAssertEqual(fromEnv.deviceId, "FILEDID")
        XCTAssertEqual(fromEnv.token, "ENVTOKEN")
        XCTAssertEqual(fromEnv.iid, "IID1")
        let fromArgs = try loadProfile(args: ["app_key": .string("ARGKEY"), "token": .string(""), "url": .null], env: env, useSessionFile: false)
        XCTAssertEqual(fromArgs.appKey, "ARGKEY") // args beat env
        XCTAssertEqual(fromArgs.token, "ENVTOKEN") // empty arg ignored
        XCTAssertEqual(fromArgs.url, "wss://file/ws")
        XCTAssertThrowsError(try loadProfile(env: ["TYPELESS_CONFIG": "/nonexistent/x.json"], useSessionFile: false))
    }

    func testSessionFileTokenFallbackIsReadOnlyAndLowestPriority() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString).json").path
        try writeFile(path: tmp, bytes: Array("{\"token_present\":true,\"asr_token\":\"SESSTOKEN\"}".utf8))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertEqual(defaultSessionPath(env: ["TYPELESS_SESSION": tmp]), tmp)
        XCTAssertEqual(try loadProfile(env: ["TYPELESS_SESSION": tmp]).token, "SESSTOKEN")
        XCTAssertEqual(try loadProfile(env: ["TYPELESS_SESSION": tmp, "TYPELESS_ASR_TOKEN": "ENVTOKEN"]).token, "ENVTOKEN")
        XCTAssertEqual(sessionToken(loadSession(path: "/nonexistent/session.json")), "")
    }

    func testWSSURLMergeAndHeaders() {
        XCTAssertEqual(buildWSSURL("wss://h/ws", deviceId: "d", aid: "1", appkey: "k"), "wss://h/ws?device_id=d&aid=1&appkey=k")
        XCTAssertEqual(buildWSSURL("wss://h/ws?device_id=old&x=1", deviceId: "new", aid: "1", appkey: ""), "wss://h/ws?device_id=old&x=1&aid=1")
        XCTAssertEqual(buildWSSURL("wss://frontier-ime.doubao.com/ws/v2#f", deviceId: "d", aid: "", appkey: ""), "wss://frontier-ime.doubao.com/ws/v2?device_id=d#f")
        XCTAssertEqual(ASRProfile().websocketURL(), "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws?device_id=7418239102837461&aid=685343&appkey=OrnqKvSSrs")
        XCTAssertTrue(isObservedWSSURL("wss://frontier-audio-ime-quic.doubao.com/api/v1/ws?x=1"))
        XCTAssertFalse(isObservedWSSURL("wss://other/ws"))
        var p = ASRProfile(appKey: "AK")
        p.ssDp = "DP"
        XCTAssertEqual(p.headers().map { "\($0.0)=\($0.1)" }, [
            "proto-version=v2", "x-ttnet-protocol-handler=1", "x-custom-keepalive=true",
            "x-keepalive-interval=3", "x-keepalive-timeout=3600", "appkey=AK", "x-api-app-key=AK", "X-SS-DP=DP",
        ])
        XCTAssertEqual(ASRProfile(appKey: "").headers().count, 5)
    }

    func testValidateListenHost() throws {
        XCTAssertEqual(try validateListenHost(nil), "127.0.0.1")
        XCTAssertEqual(try validateListenHost("  "), "127.0.0.1")
        XCTAssertEqual(try validateListenHost("::1"), "::1")
        for bad in ["0.0.0.0", "::", "[::]"] { XCTAssertThrowsError(try validateListenHost(bad)) }
    }
}

// MARK: - helpers

func syntheticPCM(frames: Int, seed: UInt32 = 777) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: frames * frameBytes)
    var lcg = seed
    out.withUnsafeMutableBytes { raw in
        for i in 0..<(frames * frameSamples) {
            lcg = lcg &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: lcg) >> 8) / Double(1 << 23) * 0.05
            let t = Double(i) / Double(sampleRate)
            let v = 0.3 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 1340 * t) + noise
            raw.storeBytes(of: Int16(max(-32768, min(32767, v * 32767))).littleEndian, toByteOffset: i * 2, as: Int16.self)
        }
    }
    return out
}
