// Protobuf wire types 0/1/2/5 used by the ASR envelope (spec §8).

public enum WireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

public let maxVarintBytes = 10

public enum WireError: Error, Equatable, CustomStringConvertible, Sendable {
    case varintUnsigned
    case varintTruncated
    case varintTooLong
    case fieldNumberZero
    case unsupportedWireType(Int)
    case lengthExceedsBuffer
    case fixed64Truncated
    case fixed32Truncated
    case fixedSize(String)
    /// EnvelopeError in the Python tree (subclass of WireError there too).
    case envelope(String)

    public var description: String {
        switch self {
        case .varintUnsigned: return "varint must be unsigned"
        case .varintTruncated: return "varint truncated"
        case .varintTooLong: return "varint exceeds 10 bytes"
        case .fieldNumberZero: return "field number 0"
        case .unsupportedWireType(let t): return "unsupported wire type \(t)"
        case .lengthExceedsBuffer: return "length exceeds remaining buffer"
        case .fixed64Truncated: return "fixed64 truncated"
        case .fixed32Truncated: return "fixed32 truncated"
        case .fixedSize(let m): return m
        case .envelope(let m): return m
        }
    }
}

/// Append-only protobuf writer over a contiguous `[UInt8]`. Reusable: call `reset()` between
/// messages to keep the capacity (no per-frame allocation on the hot path).
public struct ProtoWriter {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 512) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    @inline(__always)
    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    @inline(__always)
    public mutating func writeKey(_ field: Int, _ type: WireType) {
        writeVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    public mutating func writeVarintField(_ field: Int, _ value: UInt64) {
        writeKey(field, .varint)
        writeVarint(value)
    }

    public mutating func writeBytesField(_ field: Int, _ value: UnsafeRawBufferPointer) {
        writeKey(field, .lengthDelimited)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeBytesField(_ field: Int, _ value: [UInt8]) {
        writeKey(field, .lengthDelimited)
        writeVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    public mutating func writeStringField(_ field: Int, _ value: String) {
        writeKey(field, .lengthDelimited)
        var s = value
        s.withUTF8 { utf8 in
            writeVarint(UInt64(utf8.count))
            bytes.append(contentsOf: utf8)
        }
    }

    public mutating func writeFixed64Field(_ field: Int, _ raw: [UInt8]) throws {
        guard raw.count == 8 else { throw WireError.fixedSize("fixed64 requires 8 bytes") }
        writeKey(field, .fixed64)
        bytes.append(contentsOf: raw)
    }

    public mutating func writeFixed32Field(_ field: Int, _ raw: [UInt8]) throws {
        guard raw.count == 4 else { throw WireError.fixedSize("fixed32 requires 4 bytes") }
        writeKey(field, .fixed32)
        bytes.append(contentsOf: raw)
    }
}

public func encodeVarint(_ value: UInt64) -> [UInt8] {
    var w = ProtoWriter(capacity: 10)
    w.writeVarint(value)
    return w.bytes
}

/// Returns (value, next offset). Mirrors `decode_varint` including its error conditions.
public func decodeVarint(_ buf: UnsafeRawBufferPointer, offset: Int = 0) throws -> (UInt64, Int) {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    for i in 0..<maxVarintBytes {
        let pos = offset + i
        if pos >= buf.count { throw WireError.varintTruncated }
        let byte = buf[pos]
        if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
        if byte & 0x80 == 0 { return (result, pos + 1) }
        shift += 7
    }
    throw WireError.varintTooLong
}

public func decodeVarint(_ buf: [UInt8], offset: Int = 0) throws -> (UInt64, Int) {
    try buf.withUnsafeBytes { try decodeVarint($0, offset: offset) }
}

/// A decoded field. Length-delimited / fixed values are exposed as a byte range into the
/// source buffer so the reader never copies payloads.
public struct WireField: Equatable, Sendable {
    public var number: Int
    public var type: WireType
    public var varint: UInt64
    public var range: Range<Int>

    public init(number: Int, type: WireType, varint: UInt64 = 0, range: Range<Int> = 0..<0) {
        self.number = number
        self.type = type
        self.varint = varint
        self.range = range
    }
}

public enum ProtoReader {
    /// Walks every field; unknown fields are returned (callers skip them). Errors match §8.
    public static func fields(_ buf: UnsafeRawBufferPointer) throws -> [WireField] {
        var out: [WireField] = []
        out.reserveCapacity(12)
        var offset = 0
        let end = buf.count
        while offset < end {
            let (key, next) = try decodeVarint(buf, offset: offset)
            offset = next
            let number = Int(key >> 3)
            let rawType = Int(key & 7)
            if number == 0 { throw WireError.fieldNumberZero }
            guard let type = WireType(rawValue: UInt8(rawType)) else {
                throw WireError.unsupportedWireType(rawType)
            }
            switch type {
            case .varint:
                let (value, n) = try decodeVarint(buf, offset: offset)
                out.append(WireField(number: number, type: .varint, varint: value))
                offset = n
            case .fixed64:
                let nxt = offset + 8
                if nxt > end { throw WireError.fixed64Truncated }
                out.append(WireField(number: number, type: .fixed64, range: offset..<nxt))
                offset = nxt
            case .fixed32:
                let nxt = offset + 4
                if nxt > end { throw WireError.fixed32Truncated }
                out.append(WireField(number: number, type: .fixed32, range: offset..<nxt))
                offset = nxt
            case .lengthDelimited:
                let (length, n) = try decodeVarint(buf, offset: offset)
                offset = n
                if length > UInt64(end - offset) { throw WireError.lengthExceedsBuffer }
                let nxt = offset + Int(length)
                out.append(WireField(number: number, type: .lengthDelimited, range: offset..<nxt))
                offset = nxt
            }
        }
        return out
    }

    public static func fields(_ buf: [UInt8]) throws -> [WireField] {
        try buf.withUnsafeBytes { try fields($0) }
    }
}
