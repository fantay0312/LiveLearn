// Minimal RFC 6455 frame codec used by the loopback Adapter server (and tests).
// Unmasking runs 8 bytes per step in C (`typeless_ws_xor`), replacing the Python per-byte loop.
import Foundation
import COpusShim
import TypelessCore

public enum WSOpcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

public enum WSMessage: Equatable, Sendable {
    case text([UInt8])
    case binary([UInt8])
    case ping([UInt8])
    case pong([UInt8])
    case close(code: UInt16?, reason: [UInt8])
}

public enum WebSocketError: Error, CustomStringConvertible, Equatable {
    case badOpcode(UInt8)
    case reservedBits
    case fragmentedControlFrame
    case unexpectedContinuation
    case interleavedDataFrame
    case messageTooLarge(Int)
    case controlFrameTooLarge
    case handshake(String)
    case closed
    public var description: String {
        switch self {
        case .badOpcode(let o): return "bad opcode \(o)"
        case .reservedBits: return "reserved bits set"
        case .fragmentedControlFrame: return "fragmented control frame"
        case .unexpectedContinuation: return "continuation without start frame"
        case .interleavedDataFrame: return "new data frame while fragment pending"
        case .messageTooLarge(let n): return "message exceeds \(n) bytes"
        case .controlFrameTooLarge: return "control frame payload exceeds 125 bytes"
        case .handshake(let m): return m
        case .closed: return "connection closed"
        }
    }
}

public let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

public func wsAcceptKey(_ secKey: String) -> String {
    Data(sha1Digest(Array((secKey + wsGUID).utf8))).base64EncodedString()
}

public func randomMaskKey() -> [UInt8] {
    var k = [UInt8](repeating: 0, count: 4)
    _ = SecRandomCopyBytes(kSecRandomDefault, 4, &k)
    return k
}

/// Encodes one unfragmented frame. Server frames are unmasked; client frames masked.
public func wsEncodeFrame(_ payload: UnsafeRawBufferPointer, opcode: WSOpcode, mask: Bool, maskKey: [UInt8]? = nil) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(payload.count + 14)
    out.append(0x80 | opcode.rawValue)
    let maskBit: UInt8 = mask ? 0x80 : 0
    let n = payload.count
    if n < 126 {
        out.append(maskBit | UInt8(n))
    } else if n < 65536 {
        out.append(maskBit | 126)
        out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
    } else {
        out.append(maskBit | 127)
        for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
    }
    if mask {
        let key = maskKey ?? randomMaskKey()
        out.append(contentsOf: key)
        let start = out.count
        out.append(contentsOf: payload)
        out.withUnsafeMutableBytes { raw in
            key.withUnsafeBufferPointer { k in
                typeless_ws_xor(raw.baseAddress! + start, n, k.baseAddress!, 0)
            }
        }
    } else {
        out.append(contentsOf: payload)
    }
    return out
}

public func wsEncodeFrame(_ payload: [UInt8], opcode: WSOpcode, mask: Bool, maskKey: [UInt8]? = nil) -> [UInt8] {
    payload.withUnsafeBytes { wsEncodeFrame($0, opcode: opcode, mask: mask, maskKey: maskKey) }
}

public func wsEncodeClose(code: UInt16 = 1000, reason: String = "", mask: Bool) -> [UInt8] {
    var payload: [UInt8] = [UInt8(code >> 8), UInt8(code & 0xFF)]
    payload.append(contentsOf: reason.utf8)
    return wsEncodeFrame(payload, opcode: .close, mask: mask)
}

/// Incremental frame parser: feed arbitrary byte chunks, receive complete messages.
/// Handles masking, 16/64-bit lengths, fragmentation (continuation frames) and control frames
/// interleaved inside a fragmented message.
public final class WSFrameParser {
    private var buffer: [UInt8] = []
    private var readOffset = 0
    private var fragmentOpcode: WSOpcode? = nil
    private var fragments: [UInt8] = []
    public let maxMessageSize: Int
    public private(set) var closed = false

    public init(maxMessageSize: Int = 2 * 1024 * 1024) {
        self.maxMessageSize = maxMessageSize
        buffer.reserveCapacity(64 * 1024)
    }

    public var buffered: Int { buffer.count - readOffset }

    public func feed(_ data: UnsafeRawBufferPointer) throws -> [WSMessage] {
        if readOffset > 0 && readOffset >= buffer.count / 2 {
            buffer.removeFirst(readOffset)
            readOffset = 0
        }
        buffer.append(contentsOf: data)
        var out: [WSMessage] = []
        while let msg = try parseOne() {
            if let m = msg { out.append(m) }
        }
        return out
    }

    public func feed(_ data: [UInt8]) throws -> [WSMessage] { try data.withUnsafeBytes { try feed($0) } }

    /// Returns `.some(nil)` when a frame was consumed without producing a message (fragment).
    private func parseOne() throws -> WSMessage?? {
        let avail = buffer.count - readOffset
        if avail < 2 { return nil }
        let b0 = buffer[readOffset]
        let b1 = buffer[readOffset + 1]
        let fin = b0 & 0x80 != 0
        if b0 & 0x70 != 0 { throw WebSocketError.reservedBits }
        let rawOpcode = b0 & 0x0F
        guard let opcode = WSOpcode(rawValue: rawOpcode) else { throw WebSocketError.badOpcode(rawOpcode) }
        let masked = b1 & 0x80 != 0
        var length = Int(b1 & 0x7F)
        var header = 2
        if length == 126 {
            if avail < 4 { return nil }
            length = Int(buffer[readOffset + 2]) << 8 | Int(buffer[readOffset + 3])
            header = 4
        } else if length == 127 {
            if avail < 10 { return nil }
            var v: UInt64 = 0
            for i in 0..<8 { v = v << 8 | UInt64(buffer[readOffset + 2 + i]) }
            if v > UInt64(maxMessageSize) { throw WebSocketError.messageTooLarge(maxMessageSize) }
            length = Int(v)
            header = 10
        }
        if length > maxMessageSize { throw WebSocketError.messageTooLarge(maxMessageSize) }
        let maskLen = masked ? 4 : 0
        let total = header + maskLen + length
        if avail < total { return nil }
        let payloadStart = readOffset + header + maskLen
        if masked {
            let keyStart = readOffset + header
            buffer.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                typeless_ws_xor(base + payloadStart, length, base + keyStart, 0)
            }
        }
        let payload = Array(buffer[payloadStart..<payloadStart + length])
        readOffset += total
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        }

        switch opcode {
        case .ping, .pong, .close:
            if !fin { throw WebSocketError.fragmentedControlFrame }
            if length > 125 { throw WebSocketError.controlFrameTooLarge }
            if opcode == .ping { return .some(.ping(payload)) }
            if opcode == .pong { return .some(.pong(payload)) }
            closed = true
            var code: UInt16? = nil
            var reason: [UInt8] = []
            if payload.count >= 2 {
                code = UInt16(payload[0]) << 8 | UInt16(payload[1])
                reason = Array(payload[2...])
            }
            return .some(.close(code: code, reason: reason))
        case .continuation:
            guard let startOpcode = fragmentOpcode else { throw WebSocketError.unexpectedContinuation }
            if fragments.count + payload.count > maxMessageSize { throw WebSocketError.messageTooLarge(maxMessageSize) }
            fragments.append(contentsOf: payload)
            if fin {
                let whole = fragments
                fragments = []
                fragmentOpcode = nil
                return .some(startOpcode == .text ? .text(whole) : .binary(whole))
            }
            return .some(nil)
        case .text, .binary:
            if fragmentOpcode != nil { throw WebSocketError.interleavedDataFrame }
            if fin { return .some(opcode == .text ? .text(payload) : .binary(payload)) }
            fragmentOpcode = opcode
            fragments = payload
            return .some(nil)
        }
    }
}

// MARK: - HTTP/1.1 head parsing (handshake + /health)

public struct HTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var target: String
    public var version: String
    /// Lower-cased header names.
    public var headers: [String: String]

    public var path: String {
        if let q = target.firstIndex(of: "?") { return String(target[..<q]) }
        return target
    }
}

public enum HTTPParseResult { case incomplete, tooLarge, parsed(HTTPRequestHead, bodyStart: Int) }

/// Finds `\r\n\r\n`; returns the head and the offset where the body/frames begin.
public func parseHTTPHead(_ buf: [UInt8], limit: Int = 64 * 1024) -> HTTPParseResult {
    let n = buf.count
    var end = -1
    if n >= 4 {
        var i = 0
        while i + 3 < n {
            if buf[i] == 0x0D, buf[i + 1] == 0x0A, buf[i + 2] == 0x0D, buf[i + 3] == 0x0A { end = i; break }
            i += 1
        }
    }
    if end < 0 { return n > limit ? .tooLarge : .incomplete }
    if end > limit { return .tooLarge }
    let head = String(decoding: buf[0..<end], as: UTF8.self)
    let lines = head.components(separatedBy: "\r\n")
    let parts = lines.first?.split(separator: " ", omittingEmptySubsequences: true) ?? []
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }
    let reqHead = HTTPRequestHead(
        method: parts.count > 0 ? String(parts[0]) : "",
        target: parts.count > 1 ? String(parts[1]) : "/",
        version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
        headers: headers)
    return .parsed(reqHead, bodyStart: end + 4)
}

public func buildHTTPResponse(status: Int, reason: String, body: [UInt8], extraHeaders: [(String, String)] = [],
                              contentType: String = "application/json; charset=utf-8") -> [UInt8] {
    var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Type: \(contentType)", "Content-Length: \(body.count)", "Connection: close"]
    for (k, v) in extraHeaders { lines.append("\(k): \(v)") }
    var out = Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    out.append(contentsOf: body)
    return out
}

public func buildHandshakeResponse(secKey: String) -> [UInt8] {
    Array(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
           "Sec-WebSocket-Accept: \(wsAcceptKey(secKey))\r\n\r\n").utf8)
}
