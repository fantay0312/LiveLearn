// dump-proto and log redaction (spec §25, credential_setup.md): never print token / appkey /
// PEM / full device_id; show `<redacted len=.. sha256_12=..>` instead.

public let secretJSONKeys: Set<String> = [
    "token", "appkey", "app_key", "device_id", "did", "api_access_key", "api_app_key",
    "authorization", "client_key_pem", "client_cert_pem", "ca_pem",
]

private let pemMarkers: [[UInt8]] = [Array("-----BEGIN".utf8), Array("PRIVATE KEY".utf8), Array("CERTIFICATE".utf8)]

func containsBytes(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, hay.count >= needle.count else { return false }
    var i = 0
    let last = hay.count - needle.count
    while i <= last {
        if hay[i] == needle[0] {
            var ok = true
            for k in 1..<needle.count where hay[i + k] != needle[k] { ok = false; break }
            if ok { return true }
        }
        i += 1
    }
    return false
}

func looksSecretBytes(_ value: [UInt8]) -> Bool { pemMarkers.contains { containsBytes(value, $0) } }

public func redactJSON(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let obj):
        var out = JSONObject()
        for (k, v) in obj.pairs {
            out.pairs.append((k, secretJSONKeys.contains(k.lowercased()) ? .string("<redacted>") : redactJSON(v)))
        }
        return .object(out)
    case .array(let items): return .array(items.map(redactJSON))
    default: return value
    }
}

/// Python `repr(str)`: single quotes unless the text contains `'` and no `"`.
func pythonRepr(_ text: String) -> String {
    let useDouble = text.contains("'") && !text.contains("\"")
    let quote: Character = useDouble ? "\"" : "'"
    var out = String(quote)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case _ where scalar.value < 0x20 || scalar.value == 0x7F:
            out += String(format: "\\x%02x", scalar.value)
        case _ where Character(scalar) == quote:
            out += "\\" + String(quote)
        default: out.unicodeScalars.append(scalar)
        }
    }
    out.append(quote)
    return out
}

func formatLenValue(_ value: [UInt8], secret: Bool) -> String {
    if secret || looksSecretBytes(value) {
        return "<redacted len=\(value.count) sha256_12=\(sha12(value))>"
    }
    guard let text = String(bytes: value, encoding: .utf8) else {
        return "bytes len=\(value.count) sha256_12=\(sha12(value))"
    }
    if let first = text.first, first == "{" || first == "[" {
        if let parsed = try? JSONParser.parse(value) {
            return "json \(redactJSON(parsed).compactJSON())"
        }
    }
    if text.unicodeScalars.count > 120 {
        return "string len=\(text.unicodeScalars.count) sha256_12=\(sha12(value))"
    }
    return "string \(pythonRepr(text))"
}

/// Print field numbers and wire types without raw credentials.
public func dumpProto(_ buf: [UInt8], asRequest: Bool? = nil) throws -> String {
    let fields = try ProtoReader.fields(buf)
    var isRequest = asRequest
    if isRequest == nil {
        let names = Set(fields.map { $0.number })
        isRequest = names.contains(2) && names.contains(5) && !names.contains(11)
    }
    let request = isRequest!
    let schema = request ? requestFields : responseFields
    var lines = [request ? "kind=WebSocketRequest" : "kind=WebSocketResponse"]
    for item in fields {
        let name = schema[item.number]?.0 ?? "unknown"
        let rendered: String
        if item.type == .varint {
            rendered = "varint \(item.varint)"
        } else {
            let raw = Array(buf[item.range])
            let secret = secretJSONKeys.contains(name) || (request && (item.number == 1 || item.number == 2))
            rendered = formatLenValue(raw, secret: secret)
        }
        lines.append("field=\(item.number) name=\(name) wire=\(item.type.rawValue) \(rendered)")
    }
    return lines.joined(separator: "\n")
}
