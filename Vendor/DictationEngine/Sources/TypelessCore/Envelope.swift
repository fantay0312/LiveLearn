// ASR WebSocketRequest / WebSocketResponse protobuf envelopes (spec §9).

public enum FieldKind: Sendable { case string, bytes, uint64 }

public let requestFields: [Int: (String, FieldKind)] = [
    1: ("token", .string),
    2: ("appkey", .string),
    3: ("namespace", .string),
    4: ("version", .string),
    5: ("event", .string),
    6: ("payload", .bytes),
    7: ("data", .bytes),
    8: ("task_id", .string),
    9: ("seq_id", .uint64),
    10: ("session_id", .string),
]

public let responseFields: [Int: (String, FieldKind)] = [
    1: ("task_id", .string),
    2: ("message_id", .string),
    3: ("namespace", .string),
    4: ("event", .string),
    5: ("status_code", .uint64),
    6: ("status_text", .string),
    7: ("payload", .bytes),
    8: ("data", .bytes),
    9: ("seq_id", .uint64),
    10: ("session_id", .string),
    11: ("request_id", .string),
]

@inline(__always)
private func utf8String(_ buf: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
    String(decoding: UnsafeRawBufferPointer(rebasing: buf[range]), as: UTF8.self)
}

public struct WebSocketRequest: Equatable, Sendable {
    public var token: String = ""
    public var appkey: String = ""
    public var namespace: String = ""
    public var version: String = ""
    public var event: String = ""
    public var payload: [UInt8] = []
    public var data: [UInt8] = []
    public var taskId: String = ""
    public var seqId: UInt64 = 0
    public var sessionId: String = ""

    public init(
        token: String = "", appkey: String = "", namespace: String = "", version: String = "",
        event: String = "", payload: [UInt8] = [], data: [UInt8] = [], taskId: String = "",
        seqId: UInt64 = 0, sessionId: String = ""
    ) {
        self.token = token
        self.appkey = appkey
        self.namespace = namespace
        self.version = version
        self.event = event
        self.payload = payload
        self.data = data
        self.taskId = taskId
        self.seqId = seqId
        self.sessionId = sessionId
    }

    /// Field-number order; empty strings/bytes and 0 are omitted (spec §9.2).
    public func encode(into w: inout ProtoWriter) {
        if !token.isEmpty { w.writeStringField(1, token) }
        if !appkey.isEmpty { w.writeStringField(2, appkey) }
        if !namespace.isEmpty { w.writeStringField(3, namespace) }
        if !version.isEmpty { w.writeStringField(4, version) }
        if !event.isEmpty { w.writeStringField(5, event) }
        if !payload.isEmpty { w.writeBytesField(6, payload) }
        if !data.isEmpty { w.writeBytesField(7, data) }
        if !taskId.isEmpty { w.writeStringField(8, taskId) }
        if seqId != 0 { w.writeVarintField(9, seqId) }
        if !sessionId.isEmpty { w.writeStringField(10, sessionId) }
    }

    public func encode() -> [UInt8] {
        var w = ProtoWriter(capacity: 64 + payload.count + data.count + token.utf8.count)
        encode(into: &w)
        return w.bytes
    }

    public static func decode(_ buf: [UInt8]) throws -> WebSocketRequest {
        try buf.withUnsafeBytes { try decode($0) }
    }

    public static func decode(_ buf: UnsafeRawBufferPointer) throws -> WebSocketRequest {
        var out = WebSocketRequest()
        for item in try ProtoReader.fields(buf) {
            guard let (_, kind) = requestFields[item.number] else { continue }
            switch kind {
            case .string, .bytes:
                guard item.type == .lengthDelimited else {
                    throw WireError.envelope("field \(item.number) expected \(kind == .string ? "string" : "bytes")")
                }
            case .uint64:
                guard item.type == .varint else { throw WireError.envelope("field \(item.number) expected varint") }
            }
            switch item.number {
            case 1: out.token = utf8String(buf, item.range)
            case 2: out.appkey = utf8String(buf, item.range)
            case 3: out.namespace = utf8String(buf, item.range)
            case 4: out.version = utf8String(buf, item.range)
            case 5: out.event = utf8String(buf, item.range)
            case 6: out.payload = Array(buf[item.range])
            case 7: out.data = Array(buf[item.range])
            case 8: out.taskId = utf8String(buf, item.range)
            case 9: out.seqId = item.varint
            case 10: out.sessionId = utf8String(buf, item.range)
            default: break
            }
        }
        return out
    }
}

public struct WebSocketResponse: Equatable, Sendable {
    public var taskId: String = ""
    public var messageId: String = ""
    public var namespace: String = ""
    public var event: String = ""
    public var statusCode: UInt64 = 0
    public var statusText: String = ""
    public var payload: [UInt8] = []
    public var data: [UInt8] = []
    public var seqId: UInt64 = 0
    public var sessionId: String = ""
    public var requestId: String = ""

    public init(
        taskId: String = "", messageId: String = "", namespace: String = "", event: String = "",
        statusCode: UInt64 = 0, statusText: String = "", payload: [UInt8] = [], data: [UInt8] = [],
        seqId: UInt64 = 0, sessionId: String = "", requestId: String = ""
    ) {
        self.taskId = taskId
        self.messageId = messageId
        self.namespace = namespace
        self.event = event
        self.statusCode = statusCode
        self.statusText = statusText
        self.payload = payload
        self.data = data
        self.seqId = seqId
        self.sessionId = sessionId
        self.requestId = requestId
    }

    public func encode(into w: inout ProtoWriter) {
        if !taskId.isEmpty { w.writeStringField(1, taskId) }
        if !messageId.isEmpty { w.writeStringField(2, messageId) }
        if !namespace.isEmpty { w.writeStringField(3, namespace) }
        if !event.isEmpty { w.writeStringField(4, event) }
        if statusCode != 0 { w.writeVarintField(5, statusCode) }
        if !statusText.isEmpty { w.writeStringField(6, statusText) }
        if !payload.isEmpty { w.writeBytesField(7, payload) }
        if !data.isEmpty { w.writeBytesField(8, data) }
        if seqId != 0 { w.writeVarintField(9, seqId) }
        if !sessionId.isEmpty { w.writeStringField(10, sessionId) }
        if !requestId.isEmpty { w.writeStringField(11, requestId) }
    }

    public func encode() -> [UInt8] {
        var w = ProtoWriter(capacity: 64 + payload.count + data.count)
        encode(into: &w)
        return w.bytes
    }

    public static func decode(_ buf: [UInt8]) throws -> WebSocketResponse {
        try buf.withUnsafeBytes { try decode($0) }
    }

    public static func decode(_ buf: UnsafeRawBufferPointer) throws -> WebSocketResponse {
        var out = WebSocketResponse()
        for item in try ProtoReader.fields(buf) {
            guard let (_, kind) = responseFields[item.number] else { continue }
            switch kind {
            case .string, .bytes:
                guard item.type == .lengthDelimited else {
                    throw WireError.envelope("field \(item.number) expected \(kind == .string ? "string" : "bytes")")
                }
            case .uint64:
                guard item.type == .varint else { throw WireError.envelope("field \(item.number) expected varint") }
            }
            switch item.number {
            case 1: out.taskId = utf8String(buf, item.range)
            case 2: out.messageId = utf8String(buf, item.range)
            case 3: out.namespace = utf8String(buf, item.range)
            case 4: out.event = utf8String(buf, item.range)
            case 5: out.statusCode = item.varint
            case 6: out.statusText = utf8String(buf, item.range)
            case 7: out.payload = Array(buf[item.range])
            case 8: out.data = Array(buf[item.range])
            case 9: out.seqId = item.varint
            case 10: out.sessionId = utf8String(buf, item.range)
            case 11: out.requestId = utf8String(buf, item.range)
            default: break
            }
        }
        return out
    }
}
