// `test-offline`: the §28.1 MUST matrix as in-binary self-checks (the XCTest suite in
// Tests/ covers the same matrix plus networking/e2e; this runs without a toolchain).
import Foundation
import TypelessCore
import TypelessNet

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ cond: Bool, _ message: @autoclosure () -> String) throws {
    if !cond { throw CheckFailure(message: message()) }
}

func expectThrows(_ body: () throws -> Void, _ message: String) throws {
    var threw = false
    do { try body() } catch { threw = true }
    try expect(threw, message)
}

let selfChecks: [(String, () throws -> Void)] = [
    ("wire.varint_round_trip", {
        for value: UInt64 in [0, 1, 127, 128, 300, 1 << 32, UInt64.max] {
            let enc = encodeVarint(value)
            let (dec, off) = try decodeVarint(enc)
            try expect(dec == value && off == enc.count, "varint \(value)")
        }
    }),
    ("wire.varint_truncated_too_long_field0_wiretype", {
        try expectThrows({ _ = try decodeVarint([0x80]) }, "truncated")
        try expectThrows({ _ = try decodeVarint([]) }, "empty")
        try expectThrows({ _ = try decodeVarint([UInt8](repeating: 0x80, count: 10)) }, "too long")
        try expectThrows({ _ = try ProtoReader.fields(encodeVarint(0)) }, "field 0")
        try expectThrows({ _ = try ProtoReader.fields(encodeVarint((1 << 3) | 3) + [0]) }, "wire type 3")
    }),
    ("envelope.field_numbers_omit_zeros_round_trip", {
        let req = WebSocketRequest(token: "t", appkey: "k", namespace: "ASR", event: "StartTask", taskId: "TASK")
        try expect(try ProtoReader.fields(req.encode()).map { $0.number } == [1, 2, 3, 5, 8], "request field numbers")
        let full = WebSocketRequest(token: "tok", appkey: "key", namespace: "ASR", event: "TaskRequest",
                                    payload: Array("{\"timestamp_ms\":1}".utf8), data: [0xBB, 0x42, 0x01] + [UInt8](repeating: 0, count: 317),
                                    taskId: "ABC", seqId: 3, sessionId: "s1")
        try expect(try WebSocketRequest.decode(full.encode()) == full, "request round trip")
        let resp = WebSocketResponse(taskId: "ABC", namespace: "ASR", event: "ASRResponse", statusCode: 20000000,
                                     payload: Array("{\"results\":[]}".utf8), seqId: 3, sessionId: "s1", requestId: "r1")
        try expect(try WebSocketResponse.decode(resp.encode()) == resp, "response round trip")
        try expect(try ProtoReader.fields(resp.encode()).map { $0.number } == [1, 3, 4, 5, 7, 9, 10, 11], "response field numbers")
    }),
    ("envelope.dump_proto_redacts_secrets", {
        let req = WebSocketRequest(token: "SECRETTOKENVALUE", appkey: "SECRETAPPKEY", namespace: "ASR", event: "StartTask", taskId: "TASK")
        let dumped = try dumpProto(req.encode())
        try expect(dumped.contains("field=1") && dumped.contains("field=2") && dumped.contains("field=5"), "fields listed")
        try expect(!dumped.contains("SECRETTOKENVALUE") && !dumped.contains("SECRETAPPKEY"), "secrets redacted")
        try expect(dumped.contains("<redacted len=16 sha256_12="), "redaction format")
    }),
    ("opus.20ms_159_40ms_320_bb4201", {
        let enc = try SpeechOpusEncoder()
        try expect(try enc.encode20ms([UInt8](repeating: 0, count: 640)).count == opusCBRFrameBytes, "159 bytes")
        let packet = try enc.encode40ms([UInt8](repeating: 0, count: frameBytes))
        try expect(packet.count == speechOpusPacketBytes && Array(packet[0..<3]) == speechOpusPrefix, "320 + bb4201")
    }),
    ("transcript.two_pass_picks_last_revision_and_final", {
        let ev = normalizePayload(.obj([("results", .array([
            .obj([("text", .string("扣德克斯")), ("is_interim", .bool(true))]),
            .obj([("text", .string("Codex")), ("is_interim", .bool(true))]),
        ]))]))
        try expect(ev?.text == "Codex", "last revision")
        let fin = normalizePayload(.obj([("results", .array([
            .obj([("text", .string("first")), ("is_interim", .bool(false))]),
            .obj([("text", .string("second")), ("is_interim", .bool(false))]),
            .string("ignore-me"),
        ]))]))
        try expect(fin?.text == "second" && fin?.isFinal == true, "last final")
    }),
    ("transcript.empty_text_requires_vad_start", {
        let emptyResult: JSONValue = .obj([("text", .string("")), ("is_interim", .bool(true))])
        try expect(normalizePayload(.obj([("results", .array([emptyResult]))])) == nil, "drop empty")
        let vadResult: JSONValue = .obj([("text", .string("")), ("is_interim", .bool(true)), ("extra", .obj([("vad_start", .int(1))]))])
        let ev = normalizePayload(.obj([("results", .array([vadResult]))]))
        try expect(ev?.text == "", "keep vad_start")
    }),
    ("transcript.vad_dedup_and_interim_suffix", {
        var tl = TranscriptTimeline()
        tl.update(TranscriptEvent(text: "hi", isFinal: true, startTime: 0, endTime: 1))
        tl.update(TranscriptEvent(text: "hi", isFinal: true, startTime: 0, endTime: 1))
        try expect(tl.text == "hi", "dedup")
        tl.update(TranscriptEvent(text: "hello", isFinal: true, startTime: 0, endTime: 1.2))
        try expect(tl.text == "hihello", "append segment")
        tl.update(TranscriptEvent(text: "hihello world", isFinal: true, startTime: 0, endTime: 2))
        try expect(tl.text == "hihello world", "cumulative final")
        var tl2 = TranscriptTimeline()
        tl2.update(TranscriptEvent(text: "你好", isFinal: true, startTime: 0, endTime: 1))
        tl2.update(TranscriptEvent(text: "你好世界", isFinal: false, startTime: 0, endTime: 2))
        try expect(tl2.text == "你好世界" && tl2.currentHypothesis == "世界", "interim suffix")
    }),
    ("transcript.session_final_gate", {
        var gate = SessionFinalGate()
        try expect(!gate.canEmit(), "closed initially")
        gate.markLocalFinish()
        try expect(!gate.canEmit(), "needs remote")
        gate.markRemoteFinished()
        try expect(gate.canEmit(), "open")
        gate.markSent()
        try expect(!gate.canEmit(), "once")
    }),
    ("session.pending_last_packet_finish_audio", {
        var buf = PendingPacketBuffer()
        try expect(buf.push([UInt8](repeating: 0x41, count: 320)) == nil, "first held")
        let first = buf.push([UInt8](repeating: 0x42, count: 320))
        try expect(first?.finishAudio == false && first?.seqId == 1, "second releases first")
        let last = buf.finish()
        try expect(last.finishAudio && last.seqId == 2 && last.data == [UInt8](repeating: 0x42, count: 320), "finish carries last")
        var emptyBuf = PendingPacketBuffer()
        let empty = emptyBuf.finish()
        try expect(empty.finishAudio && empty.data.isEmpty && empty.seqId == 1, "empty session finish")
    }),
    ("session.mock_state_order_and_finish_audio", {
        let transport = MockTransport()
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: transport, clock: { 1000 }, idFactory: { "TASK-1" })
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "dev", appId: "685343"))
        try session.pushPacket([UInt8](repeating: 0x11, count: 320))
        try session.pushPacket([UInt8](repeating: 0x22, count: 320))
        try session.finish()
        let events = transport.sentRequests.map { $0.event }
        try expect(Array(events.prefix(2)) == ["StartTask", "StartSession"] && events.last == "FinishSession", "order")
        let tasks = transport.sentRequests.filter { $0.event == "TaskRequest" }
        try expect(tasks.map { $0.seqId } == [1, 2], "seq ids")
        try expect(!finishAudioFlag(tasks[0]) && finishAudioFlag(tasks[1]), "finish flag")
        try expect(session.remoteSessionFinished && session.transcripts.last?.text == mockFinalText, "final text")
    }),
    ("session.unexpected_event_aborts_and_wrong_mock_order_fails", {
        final class Scripted: ASRTransport {
            var onMessage: (([UInt8]) -> Void)?; var onFailure: ((Error) -> Void)?
            var bytesSent = 0; var bytesReceived = 0
            var replies: [[UInt8]]
            init(_ r: [[UInt8]]) { replies = r }
            func open(completion: @escaping (Error?) -> Void) { completion(nil) }
            func send(_ data: [UInt8]) throws { if !replies.isEmpty { onMessage?(replies.removeFirst()) } }
            func close() {}
        }
        let t = Scripted([WebSocketResponse(event: "NopeEvent").encode()])
        let session = ASRSession(profile: ASRProfile(appKey: "k"), transport: t, idFactory: { "T" })
        var err: ASRSessionError? = nil
        session.onError = { err = $0 }
        try session.start(sessionPayload: buildStartSessionPayload(deviceId: "d", appId: "1"))
        try expect(err?.message.contains("NopeEvent") == true, "unexpected event reported")
        let remote = MockASRRemote()
        let replies = remote.handle(WebSocketRequest(appkey: "k", namespace: "ASR", event: "FinishSession", taskId: "X"))
        try expect(replies.first?.event == "SessionFailed", "wrong order → SessionFailed")
    }),
    ("context.compact_json_then_standard_base64", {
        let ctx = buildChatContext(text: "光标附近文档", cursor: 6, hostId: "EDITOR", hotwords: [])
        let payload = try JSONParser.parse(buildStartSessionPayload(deviceId: "DEVICE", appId: "685343", context: ctx))
        guard let encoded = payload["extra"]?["context"]?.stringValue else { throw CheckFailure(message: "context must be a string") }
        guard let raw = Data(base64Encoded: encoded) else { throw CheckFailure(message: "standard base64") }
        try expect(!raw.contains(0x20) && !raw.contains(0x0A), "compact")
        let decoded = try JSONParser.parse([UInt8](raw))
        try expect(decoded["chatContext"]?["hostID"] == .string("EDITOR"), "hostID")
        try expect(encodeContextB64(ctx) == encoded, "same encoder")
    }),
    ("typeless.longest_source_first_non_cascade", {
        let rules = [Replacement("扣德克斯", "Codex"), Replacement("Codex", "其他值")]
        try expect(try applyReplacements("扣德克斯", rules) == "Codex", "non-cascade")
        let doc = TypelessDocument("")
        try doc.addReplacement("扣德克斯", "Codex")
        try doc.addReplacement("Codex", "其他值")
        try expect(try doc.replace("扣德克斯") == "Codex", "doc non-cascade")
        try expect(try applyReplacements("foo bar", [Replacement("foo", "one"), Replacement("foo", "two"), Replacement("bar", "")]) == "two ", "later wins, empty deletes")
        try expectThrows({ _ = try applyReplacements("x", [Replacement("", "y")]) }, "empty source illegal")
    }),
    ("typeless.cursor_window_80_20_redistribute", {
        let text = String(repeating: "a", count: 1000) + "X" + String(repeating: "b", count: 1000)
        let w = cursorWindow(text, 1000, limit: 100)
        try expect(w.cursor == 80 && w.text == String(Array(text)[920..<1020]), "80/20")
        let full = cursorWindow("hello", 2, limit: 100)
        try expect(full.text == "hello" && full.cursor == 2, "short text")
        let near = cursorWindow(text, 5, limit: 100)
        try expect(near.start == 0 && near.text.count == 100, "redistribute")
    }),
    ("typeless.preview_commit_hotwords_learn", {
        let doc = TypelessDocument("已有文档", cursorPosition: 4)
        try expect(try doc.preview("口述") == "已有文档口述" && doc.cursorPosition == 4, "preview keeps cursor")
        try expect(try doc.commit("口述") == "口述" && doc.text == "已有文档口述" && doc.cursorPosition == 6, "commit moves cursor")
        let d2 = TypelessDocument("")
        try d2.addReplacement("扣德克斯", "Codex", frequency: 10)
        try expect(d2.hotwordsFromReplacements().first == Hotword("Codex", 10), "hotword merge")
        let learned = learnUserEdit(original: "使用扣德克斯", revised: "使用Codex")
        try expect(learned?.source == "扣德克斯" && learned?.target == "Codex", "learn")
        try expect(learnUserEdit(original: "hello", revised: "hello!") == nil, "reject pure insertion")
        try expect(learnUserEdit(original: String(repeating: "a", count: 70), revised: String(repeating: "b", count: 70)) == nil, "bounded 64")
        try expect(learnUserEdit(original: "keep", revised: "keep extra") == nil, "reject insertion 2")
    }),
    ("pcm.6400_bytes_five_40ms_frames", {
        var framer = PCMFramer()
        let frames = try framer.takeFrames(incoming: [UInt8](repeating: 0, count: 6400), finish: false)
        try expect(frames.count == 5 && frames.allSatisfy { $0.count == frameBytes } && framer.pendingBytes == 0, "5 frames")
    }),
    ("adapter.health_shape_and_unique_final", {
        let body = healthPayload()
        try expect(body["ok"] == .bool(true) && body["api_version"] == .string("1"), "health")
        let blob = body.compactJSON()
        try expect(!blob.contains("token") && !blob.contains("appkey") && !blob.contains("device_id"), "health has no secrets")
        var events: [JSONValue] = []
        let conn = AdapterConnection(profile: ASRProfile(appKey: "k", deviceId: "dev")) { events.append($0) }
        try conn.onStart(.obj([("type", .string("start")), ("app", .string("EDITOR"))]))
        try expect(events.first?["type"] == .string("ready"), "ready first")
        try conn.onPCM([UInt8](repeating: 0, count: 6400))
        try conn.onFinish()
        let types = events.map { $0["type"]?.stringValue ?? "" }
        try expect(types.contains("interim") || types.contains("correction"), "interim/correction present")
        try expect(types.filter { $0 == "final" }.count == 1 && !types.contains("error"), "exactly one final")
        let fin = events.last!
        try expect(fin["asr_finished"] == .bool(true) && fin["text"] == .string(mockFinalText) && fin["raw_text"] == .string(mockFinalText), "final shape")
        try expect(conn.pcmFramesSent == 5 && !conn.gate.canEmit(), "5 packets, gate closed")
        conn.close()
    }),
    ("cometix.audio_format_session_config_extras", {
        let fmt = audioFormat()
        try expect(fmt["frameBytes"] == .int(1280) && fmt["encoding"] == .string("linear16") && fmt["opusBitrate"] == .int(63600), "audio format")
        let parsed = try parseSessionConfig("{\"did\":\"DID123\",\"appKey\":\"KEY\",\"wssUrl\":\"wss://example.test/ws\",\"mode\":\"mock\",\"inputMode\":\"audio\"}")
        try expect(parsed["device_id"] == .string("DID123") && parsed["app_key"] == .string("KEY") && parsed["url"] == .string("wss://example.test/ws"), "session config aliases")
        let extra = try JSONParser.parse(buildStartSessionPayload(deviceId: "DEVICE", appId: "685343"))["extra"]!
        try expect(extra["aid"] == .string("685343") && extra["did"] == .string("DEVICE") && extra["enable_asr_twopass"] == .bool(true)
                   && extra["enable_asr_threepass"] == .bool(false) && extra["2a_send_commands"] == .array([.string("帮我发送")])
                   && extra["use_twopass_retry"] == .bool(true) && extra["context"] == nil, "frontier extras")
    }),
    ("config.precedence_url_merge_headers_listen_host", {
        let env = ["TYPELESS_ASR_APP_KEY": "ENVKEY", "COMETIX_DID": "DID-ONLY"]
        let p = try loadProfile(args: ["app_id": .string("42")], env: env, useSessionFile: false)
        try expect(p.appKey == "ENVKEY" && p.deviceId == "DID-ONLY" && p.appId == "42", "env + args")
        let url = buildWSSURL("wss://h/ws?device_id=old", deviceId: "new", aid: "1", appkey: "k")
        try expect(url == "wss://h/ws?device_id=old&aid=1&appkey=k", "no duplicate query keys: \(url)")
        let headers = ASRProfile(appKey: "AK").headers()
        try expect(headers.contains { $0 == ("proto-version", "v2") } && headers.contains { $0 == ("x-keepalive-timeout", "3600") }
                   && headers.contains { $0 == ("appkey", "AK") } && headers.contains { $0 == ("x-api-app-key", "AK") }, "headers")
        try expectThrows({ _ = try validateListenHost("0.0.0.0") }, "refuse 0.0.0.0")
        try expectThrows({ _ = try validateListenHost("::") }, "refuse ::")
        try expect(try validateListenHost(nil) == "127.0.0.1", "default loopback")
    }),
    ("websocket.frame_codec_mask_fragment_ping", {
        let parser = WSFrameParser()
        let payload = [UInt8]((0..<1000).map { UInt8($0 & 0xFF) })
        let frame = wsEncodeFrame(payload, opcode: .binary, mask: true)
        let msgs = try parser.feed(frame)
        try expect(msgs == [.binary(payload)], "masked round trip")
        var frag1 = wsEncodeFrame(Array("hel".utf8), opcode: .text, mask: true); frag1[0] &= 0x7F
        var frag2 = wsEncodeFrame(Array("lo".utf8), opcode: .continuation, mask: true); frag2[0] |= 0x80
        let ping = wsEncodeFrame(Array("p".utf8), opcode: .ping, mask: true)
        var all = frag1; all.append(contentsOf: ping); all.append(contentsOf: frag2)
        let out = try parser.feed(Array(all[0..<7])) + parser.feed(Array(all[7...]))
        try expect(out == [.ping(Array("p".utf8)), .text(Array("hello".utf8))], "fragmentation + interleaved ping: \(out)")
    }),
]

func runSelfChecks(verbose: Bool) -> Bool {
    var passed = 0
    var failed = 0
    let t0 = monotonicNanos()
    for (name, check) in selfChecks {
        do {
            try check()
            passed += 1
            if verbose { printOut("\(name) ... ok") }
        } catch {
            failed += 1
            printOut("\(name) ... FAIL: \(error)")
        }
    }
    let secs = Double(monotonicNanos() - t0) / 1e9
    printOut(String(repeating: "-", count: 70))
    printOut("Ran \(passed + failed) checks in \(String(format: "%.3f", secs))s")
    printOut(failed == 0 ? "OK" : "FAILED (failures=\(failed))")
    return failed == 0
}
