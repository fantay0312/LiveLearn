// Ordered JSON model with a compact serializer byte-compatible with Python's
// json.dumps(obj, ensure_ascii=False, separators=(",", ":")) for the shapes this engine emits.
// Foundation's JSONSerialization is avoided: it reorders keys and is far slower for small docs.

public struct JSONObject: Equatable, Sendable {
    public var pairs: [(String, JSONValue)]

    public init(_ pairs: [(String, JSONValue)] = []) { self.pairs = pairs }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.pairs.count == rhs.pairs.count else { return false }
        for i in 0..<lhs.pairs.count where lhs.pairs[i].0 != rhs.pairs[i].0 || lhs.pairs[i].1 != rhs.pairs[i].1 {
            return false
        }
        return true
    }

    public subscript(key: String) -> JSONValue? {
        get {
            for (k, v) in pairs where k == key { return v }
            return nil
        }
        set {
            if let idx = pairs.firstIndex(where: { $0.0 == key }) {
                if let nv = newValue { pairs[idx].1 = nv } else { pairs.remove(at: idx) }
            } else if let nv = newValue {
                pairs.append((key, nv))
            }
        }
    }

    public var keys: [String] { pairs.map { $0.0 } }
    public var isEmpty: Bool { pairs.isEmpty }
    public func has(_ key: String) -> Bool { pairs.contains { $0.0 == key } }

    /// dict.update semantics: existing keys keep their position.
    public mutating func update(_ other: JSONObject) {
        for (k, v) in other.pairs { self[k] = v }
    }
}

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public static func obj(_ pairs: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(pairs)) }

    public var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    /// Python `isinstance(v, int) and not isinstance(v, bool)`.
    public var intValue: Int64? { if case .int(let i) = self { return i }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Python truthiness of the parsed JSON value.
    public var pythonTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
}

public enum JSONError: Error, CustomStringConvertible {
    case syntax(String, Int)
    public var description: String {
        switch self { case .syntax(let m, let p): return "\(m) at position \(p)" }
    }
}

// MARK: - Serialization

public extension JSONValue {
    func compactJSON() -> String {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        appendCompact(to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    func compactJSONBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        appendCompact(to: &out)
        return out
    }

    func appendCompact(to out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .int(let i): out.append(contentsOf: String(i).utf8)
        case .double(let d): out.append(contentsOf: pythonFloatRepr(d).utf8)
        case .string(let s): appendJSONString(s, to: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (idx, item) in items.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: ",")) }
                item.appendCompact(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let obj):
            out.append(UInt8(ascii: "{"))
            for (idx, pair) in obj.pairs.enumerated() {
                if idx > 0 { out.append(UInt8(ascii: ",")) }
                appendJSONString(pair.0, to: &out)
                out.append(UInt8(ascii: ":"))
                pair.1.appendCompact(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }
}

private let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

/// Python json (ensure_ascii=False) escaping: `"` `\` and control chars only.
@inline(__always)
func appendJSONString(_ s: String, to out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for b in s.utf8 {
        switch b {
        case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
        case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
        case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
        case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
        case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
        case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
        case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
        case 0x00..<0x20:
            out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hexDigits[Int(b >> 4)], hexDigits[Int(b & 0xF)]])
        default: out.append(b)
        }
    }
    out.append(UInt8(ascii: "\""))
}

/// Python float.__repr__ for finite values: shortest round-trip; exponent form when
/// exp10 < -4 or >= 16; `1e+16` style with at least two exponent digits.
public func pythonFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    // Swift's description already produces the shortest round-trip digits with the same
    // exponent thresholds (<1e-4 or >=1e16 switch to exponent form).
    var s = d.description
    if let eIdx = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        let mantissa = String(s[s.startIndex..<eIdx])
        var exp = String(s[s.index(after: eIdx)...])
        var sign = "+"
        if exp.hasPrefix("-") { sign = "-"; exp.removeFirst() } else if exp.hasPrefix("+") { exp.removeFirst() }
        if exp.count < 2 { exp = "0" + exp }
        s = mantissa + "e" + sign + exp
        return s
    }
    if !s.contains(".") { s += ".0" }
    return s
}

// MARK: - Parsing

public struct JSONParser {
    private let buf: UnsafeRawBufferPointer
    private var pos = 0
    private var depth = 0

    private init(_ buf: UnsafeRawBufferPointer) { self.buf = buf }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        try bytes.withUnsafeBytes { try parse($0) }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var s = text
        return try s.withUTF8 { try parse(UnsafeRawBufferPointer($0)) }
    }

    public static func parse(_ buf: UnsafeRawBufferPointer) throws -> JSONValue {
        var p = JSONParser(buf)
        p.skipWS()
        let v = try p.parseValue()
        p.skipWS()
        if p.pos != buf.count { throw JSONError.syntax("Extra data", p.pos) }
        return v
    }

    @inline(__always) private mutating func skipWS() {
        while pos < buf.count {
            let c = buf[pos]
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { pos += 1 } else { break }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard pos < buf.count else { throw JSONError.syntax("Expecting value", pos) }
        switch buf[pos] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "N"): try expectLiteral("NaN"); return .double(.nan)
        case UInt8(ascii: "I"): try expectLiteral("Infinity"); return .double(.infinity)
        default: return try parseNumber()
        }
    }

    private mutating func expectLiteral(_ lit: StaticString) throws {
        let n = lit.utf8CodeUnitCount
        guard pos + n <= buf.count else { throw JSONError.syntax("Expecting value", pos) }
        var ok = true
        lit.withUTF8Buffer { lb in
            for i in 0..<n where buf[pos + i] != lb[i] { ok = false; break }
        }
        guard ok else { throw JSONError.syntax("Expecting value", pos) }
        pos += n
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = pos
        var isDouble = false
        if pos < buf.count, buf[pos] == UInt8(ascii: "-") { pos += 1 }
        if pos < buf.count, buf[pos] == UInt8(ascii: "I") {
            try expectLiteral("Infinity")
            return .double(-.infinity)
        }
        var digits = 0
        while pos < buf.count, buf[pos] >= 0x30, buf[pos] <= 0x39 { pos += 1; digits += 1 }
        if pos < buf.count, buf[pos] == UInt8(ascii: ".") {
            isDouble = true
            pos += 1
            var frac = 0
            while pos < buf.count, buf[pos] >= 0x30, buf[pos] <= 0x39 { pos += 1; frac += 1 }
            if frac == 0 { throw JSONError.syntax("Expecting value", start) }
        }
        if pos < buf.count, buf[pos] == UInt8(ascii: "e") || buf[pos] == UInt8(ascii: "E") {
            isDouble = true
            pos += 1
            if pos < buf.count, buf[pos] == UInt8(ascii: "+") || buf[pos] == UInt8(ascii: "-") { pos += 1 }
            var ed = 0
            while pos < buf.count, buf[pos] >= 0x30, buf[pos] <= 0x39 { pos += 1; ed += 1 }
            if ed == 0 { throw JSONError.syntax("Expecting value", start) }
        }
        if digits == 0 { throw JSONError.syntax("Expecting value", start) }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<pos]), as: UTF8.self)
        if !isDouble, let i = Int64(text) { return .int(i) }
        guard let d = Double(text) else { throw JSONError.syntax("Invalid number", start) }
        return .double(d)
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard pos + 4 <= buf.count else { throw JSONError.syntax("Invalid \\uXXXX escape", pos) }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = buf[pos]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw JSONError.syntax("Invalid \\uXXXX escape", pos)
            }
            v = v << 4 | d
            pos += 1
        }
        return v
    }

    private mutating func parseString() throws -> String {
        pos += 1 // opening quote
        var out: [UInt8] = []
        // Fast path: scan for a run without escapes.
        while pos < buf.count {
            let c = buf[pos]
            if c == UInt8(ascii: "\"") {
                pos += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c == UInt8(ascii: "\\") {
                pos += 1
                guard pos < buf.count else { throw JSONError.syntax("Unterminated string", pos) }
                let e = buf[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try parseHex4()
                    if cp >= 0xD800, cp <= 0xDBFF, pos + 6 <= buf.count, buf[pos] == UInt8(ascii: "\\"), buf[pos + 1] == UInt8(ascii: "u") {
                        pos += 2
                        let lo = try parseHex4()
                        if lo >= 0xDC00, lo <= 0xDFFF {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        } else {
                            appendScalar(cp, to: &out)
                            cp = lo
                        }
                    }
                    appendScalar(cp, to: &out)
                default: throw JSONError.syntax("Invalid \\escape", pos - 1)
                }
                continue
            }
            if c < 0x20 { throw JSONError.syntax("Invalid control character", pos) }
            out.append(c)
            pos += 1
        }
        throw JSONError.syntax("Unterminated string", pos)
    }

    private func appendScalar(_ cp: UInt32, to out: inout [UInt8]) {
        let scalar = Unicode.Scalar(cp) ?? Unicode.Scalar(0xFFFD)!
        out.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private mutating func parseArray() throws -> JSONValue {
        pos += 1
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw JSONError.syntax("Too deeply nested", pos) }
        var items: [JSONValue] = []
        skipWS()
        if pos < buf.count, buf[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
        while true {
            skipWS()
            items.append(try parseValue())
            skipWS()
            guard pos < buf.count else { throw JSONError.syntax("Unterminated array", pos) }
            if buf[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if buf[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
            throw JSONError.syntax("Expecting ',' delimiter", pos)
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        pos += 1
        depth += 1
        defer { depth -= 1 }
        if depth > 512 { throw JSONError.syntax("Too deeply nested", pos) }
        var obj = JSONObject()
        skipWS()
        if pos < buf.count, buf[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
        while true {
            skipWS()
            guard pos < buf.count, buf[pos] == UInt8(ascii: "\"") else {
                throw JSONError.syntax("Expecting property name enclosed in double quotes", pos)
            }
            let key = try parseString()
            skipWS()
            guard pos < buf.count, buf[pos] == UInt8(ascii: ":") else { throw JSONError.syntax("Expecting ':' delimiter", pos) }
            pos += 1
            skipWS()
            let value = try parseValue()
            obj[key] = value // duplicate keys: last value wins, first position kept (dict semantics)
            skipWS()
            guard pos < buf.count else { throw JSONError.syntax("Unterminated object", pos) }
            if buf[pos] == UInt8(ascii: ",") { pos += 1; continue }
            if buf[pos] == UInt8(ascii: "}") { pos += 1; return .object(obj) }
            throw JSONError.syntax("Expecting ',' delimiter", pos)
        }
    }
}

/// `compact_json` in the Python tree.
public func compactJSON(_ value: JSONValue) -> String { value.compactJSON() }
