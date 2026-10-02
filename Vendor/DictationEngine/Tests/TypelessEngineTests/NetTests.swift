// RFC 6455 codec, HTTP head parsing, Adapter server end-to-end over real loopback sockets,
// and the audio ring/resampler units (no microphone required).
import COpusShim
import Foundation
import XCTest
@testable import TypelessAudio
@testable import TypelessCore
@testable import TypelessNet

final class WebSocketFrameTests: XCTestCase {
    func testMaskedRoundTripAllLengthClasses() throws {
        for n in [0, 1, 125, 126, 1000, 65535, 65536, 200_000] {
            let payload = [UInt8]((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let frame = wsEncodeFrame(payload, opcode: .binary, mask: true)
            let parser = WSFrameParser(maxMessageSize: 1 << 20)
            // feed in two arbitrary pieces
            let split = min(7, frame.count)
            var out = try parser.feed(Array(frame[0..<split]))
            out += try parser.feed(Array(frame[split...]))
            XCTAssertEqual(out, [.binary(payload)], "n=\(n)")
        }
    }

    func testUnmaskedServerFrameAndCloseCode() throws {
        let parser = WSFrameParser()
        XCTAssertEqual(try parser.feed(wsEncodeFrame(Array("hi".utf8), opcode: .text, mask: false)), [.text(Array("hi".utf8))])
        let out = try parser.feed(wsEncodeClose(code: 1001, reason: "bye", mask: true))
        XCTAssertEqual(out, [.close(code: 1001, reason: Array("bye".utf8))])
        XCTAssertTrue(parser.closed)
    }

    func testFragmentationWithInterleavedControlFrames() throws {
        var f1 = wsEncodeFrame(Array("hel".utf8), opcode: .text, mask: true); f1[0] &= 0x7F
        var f2 = wsEncodeFrame(Array("lo ".utf8), opcode: .continuation, mask: true); f2[0] &= 0x7F
        let ping = wsEncodeFrame(Array("p".utf8), opcode: .ping, mask: true)
        var f3 = wsEncodeFrame(Array("world".utf8), opcode: .continuation, mask: true); f3[0] |= 0x80
        let parser = WSFrameParser()
        var out: [WSMessage] = []
        for piece in [f1, f2, ping, f3] { out += try parser.feed(piece) }
        XCTAssertEqual(out, [.ping(Array("p".utf8)), .text(Array("hello world".utf8))])
    }

    func testProtocolErrors() {
        XCTAssertThrowsError(try WSFrameParser().feed([0x80 | 0x3, 0x00])) { XCTAssertEqual($0 as? WebSocketError, .badOpcode(3)) }
        XCTAssertThrowsError(try WSFrameParser().feed([0x80 | 0x40 | 0x1, 0x00])) { XCTAssertEqual($0 as? WebSocketError, .reservedBits) }
        XCTAssertThrowsError(try WSFrameParser().feed([0x80, 0x01, 0x41])) { XCTAssertEqual($0 as? WebSocketError, .unexpectedContinuation) }
        XCTAssertThrowsError(try WSFrameParser().feed([0x09, 0x01, 0x41])) { XCTAssertEqual($0 as? WebSocketError, .fragmentedControlFrame) }
        let big = wsEncodeFrame([UInt8](repeating: 0, count: 2000), opcode: .binary, mask: false)
        XCTAssertThrowsError(try WSFrameParser(maxMessageSize: 1000).feed(big)) { XCTAssertEqual($0 as? WebSocketError, .messageTooLarge(1000)) }
    }

    func testXorPhaseForOffsets() {
        // The C unmask must honour the key phase when a buffer starts mid-payload.
        let key: [UInt8] = [1, 2, 3, 4]
        var data = [UInt8](repeating: 0, count: 13)
        data.withUnsafeMutableBytes { raw in
            key.withUnsafeBufferPointer { k in typeless_ws_xor(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), 13, k.baseAddress!, 2) }
        }
        XCTAssertEqual(data, [3, 4, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3])
    }

    func testAcceptKeyAndHTTPHead() {
        XCTAssertEqual(wsAcceptKey("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let raw = Array("GET /asr?x=1 HTTP/1.1\r\nHost: a\r\nUpgrade: WebSocket\r\nSec-WebSocket-Key: k\r\n\r\nrest".utf8)
        guard case .parsed(let head, let bodyStart) = parseHTTPHead(raw) else { return XCTFail("parse") }
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.path, "/asr")
        XCTAssertEqual(head.headers["upgrade"], "WebSocket")
        XCTAssertEqual(Array(raw[bodyStart...]), Array("rest".utf8))
        guard case .incomplete = parseHTTPHead(Array("GET / HTTP/1.1\r\n".utf8)) else { return XCTFail("incomplete") }
        guard case .tooLarge = parseHTTPHead([UInt8](repeating: 0x41, count: 70_000)) else { return XCTFail("tooLarge") }
        let resp = String(decoding: buildHTTPResponse(status: 200, reason: "OK", body: Array("{}".utf8)), as: UTF8.self)
        XCTAssertTrue(resp.hasPrefix("HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"))
    }
}

final class AdapterServerTests: XCTestCase {
    var server: AdapterServer!

    override func setUpWithError() throws {
        server = try AdapterServer(host: "127.0.0.1", port: 0, profile: ASRProfile(appKey: "k", deviceId: "dev"))
        try server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testHealthAndRouting() throws {
        let (status, body) = try httpGET(host: "127.0.0.1", port: server.boundPort, path: "/health")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{\"ok\":true,\"api_version\":\"1\",\"capabilities\":[\"asr\",\"interim\",\"correction\"]}")
        XCTAssertEqual(try httpGET(host: "127.0.0.1", port: server.boundPort, path: "/convert").status, 501)
        XCTAssertEqual(try httpGET(host: "127.0.0.1", port: server.boundPort, path: "/candidate/usage").status, 501)
        XCTAssertEqual(try httpGET(host: "127.0.0.1", port: server.boundPort, path: "/hotwords?x=1").status, 501)
        let (nf, nfBody) = try httpGET(host: "127.0.0.1", port: server.boundPort, path: "/nope")
        XCTAssertEqual(nf, 404)
        XCTAssertEqual(try JSONParser.parse(nfBody)["error"]?["code"], .string("not_found"))
    }

    func testRefusesNonLoopback() {
        XCTAssertThrowsError(try AdapterServer(host: "0.0.0.0", port: 0))
        XCTAssertThrowsError(try AdapterServer(host: "::", port: 0))
    }

    func testStreamOddChunksExactlyOneFinal() throws {
        let client = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        try client.connect()
        defer { client.close() }
        client.sendText("{\"type\":\"start\",\"app\":\"EDITOR\",\"context\":\"已有文档\",\"cursor_position\":4,\"replacements\":{\"模拟\":\"Mock\"}}")
        let pcm = syntheticPCM(frames: 30) + [UInt8](repeating: 0, count: 700) // 30 full frames + tail → 31 packets
        var off = 0
        var events: [JSONValue] = []
        for chunk in [2, 1000, 3334, 1280, 5000, 1, 1].map({ $0 * 2 }) { // even byte counts, odd framing
            let n = min(chunk, pcm.count - off)
            client.sendBinary(Array(pcm[off..<off + n]))
            off += n
        }
        while off < pcm.count {
            let n = min(1234, pcm.count - off)
            client.sendBinary(Array(pcm[off..<off + n]))
            off += n
        }
        client.sendText("{\"type\":\"finish\"}")
        events = client.receiveEvents(until: "final", timeout: 10)
        let types = events.map { $0["type"]?.stringValue ?? "" }
        XCTAssertEqual(types.first, "ready")
        XCTAssertEqual(types.filter { $0 == "final" }.count, 1)
        XCTAssertEqual(types.last, "final")
        XCTAssertFalse(types.contains("error"))
        // 30 full frames streamed → 29 TaskRequests before finish (pending policy) → 29 interim events
        XCTAssertEqual(types.filter { $0 == "correction" || $0 == "interim" }.count, 29)
        let fin = events.last!
        XCTAssertEqual(fin["asr_finished"], .bool(true))
        XCTAssertEqual(fin["raw_text"], .string(mockFinalText))
        XCTAssertEqual(fin["text"], .string("Mock识别结果"))
        XCTAssertEqual(fin["document"], .string("已有文档Mock识别结果"))
        // 31 packets total → final ASRResponse end_time = 0.04 * 31
        XCTAssertEqual(fin["end_time"], .double(0.04 * 31))
        // seq_ids strictly increasing on interim events
        let seqs = events.filter { $0["type"] == .string("correction") }.compactMap { $0["seq_id"]?.intValue }
        XCTAssertEqual(seqs, Array(1...29).map { Int64($0) })
        // server closes after final
        let closeMsg = client.receive(timeout: 3)
        XCTAssertTrue(closeMsg == nil || closeMsg?.0 == .close)
    }

    func testInvalidStartAndPCMBeforeStartYieldErrorFrame() throws {
        let client = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        try client.connect()
        defer { client.close() }
        client.sendBinary([UInt8](repeating: 0, count: 1280)) // binary before start
        let events = client.receiveEvents(until: "error", timeout: 5)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"], .string("error"))
        XCTAssertEqual(events[0]["code"], .string("invalid_request"))
        XCTAssertNotNil(events[0]["error"])
        XCTAssertNotNil(events[0]["message"])

        let client2 = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        try client2.connect()
        defer { client2.close() }
        client2.sendText("{\"type\":\"start\",\"cursor_position\":\"bad\"}")
        let ev2 = client2.receiveEvents(until: "error", timeout: 5)
        XCTAssertEqual(ev2.last?["type"], .string("error"))
        XCTAssertEqual(ev2.last?["message"], .string("cursor_position must be an integer"))
    }

    func testEmptySessionFinishStillProducesFinal() throws {
        let client = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        try client.connect()
        defer { client.close() }
        client.sendText("{\"type\":\"start\"}")
        client.sendText("{\"type\":\"finish\"}")
        let events = client.receiveEvents(until: "final", timeout: 5)
        XCTAssertEqual(events.map { $0["type"]?.stringValue }, ["ready", "final"])
        XCTAssertEqual(events.last?["asr_finished"], .bool(true))
    }

    func testConcurrentSessionsAreIsolated() throws {
        let a = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        let b = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
        try a.connect(); try b.connect()
        defer { a.close(); b.close() }
        a.sendText("{\"type\":\"start\",\"context\":\"A\"}")
        b.sendText("{\"type\":\"start\",\"context\":\"B\",\"replacements\":{\"模拟\":\"B-\"}}")
        a.sendBinary([UInt8](repeating: 0, count: 2560))
        b.sendBinary([UInt8](repeating: 0, count: 3840))
        a.sendText("{\"type\":\"finish\"}")
        b.sendText("{\"type\":\"finish\"}")
        let ea = a.receiveEvents(until: "final", timeout: 5)
        let eb = b.receiveEvents(until: "final", timeout: 5)
        XCTAssertEqual(ea.last?["document"], .string("A模拟识别结果"), ea.map { $0.compactJSON() }.joined(separator: "\n"))
        XCTAssertEqual(eb.last?["document"], .string("BB-识别结果"), eb.map { $0.compactJSON() }.joined(separator: "\n"))
        XCTAssertNotEqual(ea.first?["session_id"], eb.first?["session_id"])
    }
}

final class AudioUnitTests: XCTestCase {
    func testRingBufferWrapAround() {
        let ring = SPSCRingBuffer(capacity: 8)
        let src: [Float] = [1, 2, 3, 4, 5, 6]
        src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 6) }
        var dst = [Float](repeating: 0, count: 8)
        XCTAssertEqual(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }, 4)
        XCTAssertEqual(Array(dst[0..<4]), [1, 2, 3, 4])
        let more: [Float] = [7, 8, 9, 10, 11]
        more.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 5) } // wraps
        XCTAssertEqual(ring.available, 7)
        XCTAssertEqual(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 8) }, 7)
        XCTAssertEqual(Array(dst[0..<7]), [5, 6, 7, 8, 9, 10, 11])
        let overflow = [Float](repeating: 1, count: 9)
        overflow.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 9) }
        XCTAssertEqual(ring.overruns.load(ordering: .relaxed), 1)
    }

    func testResampler48kTo16kPreservesToneLength() throws {
        let resampler = try Resampler(inputRate: 48000)
        let inputFrames = 48000 / 10 // 100 ms
        var input = [Float](repeating: 0, count: inputFrames)
        for i in 0..<inputFrames { input[i] = 0.5 * sin(2 * .pi * 440 * Double(i) / 48000).f }
        var offset = 0
        var out = [Int16](repeating: 0, count: 2000)
        var produced = 0
        while produced < 1500 {
            let got = out.withUnsafeMutableBufferPointer { buf in
                resampler.convert(into: buf.baseAddress! + produced, frames: 320) { dst, max in
                    let n = min(max, inputFrames - offset)
                    if n > 0 { input.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + offset, count: n) } }
                    offset += n
                    return n
                }
            }
            if got == 0 { break }
            produced += got
        }
        XCTAssertGreaterThanOrEqual(produced, 1500) // ~1600 minus filter latency
        // Zero crossings of a 440 Hz tone over ~0.09 s ≈ 80
        var crossings = 0
        for i in 1..<produced where (out[i - 1] < 0) != (out[i] < 0) { crossings += 1 }
        XCTAssertGreaterThan(crossings, 60)
        XCTAssertLessThan(crossings, 100)
        let peak = out[0..<produced].map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 12000)
        XCTAssertLessThan(peak, 20000)
    }

    func testDeviceEnumerationDoesNotCrash() {
        // No assertion on count (CI boxes may have no input device); exercise the property code.
        for device in AudioDevices.listInput() {
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertGreaterThan(device.inputChannels, 0)
        }
    }
}

private extension Double { var f: Float { Float(self) } }
