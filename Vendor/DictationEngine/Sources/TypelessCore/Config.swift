// ASR profile loading: args > env > 0600 file > session.json token fallback > defaults (spec §7).
import Foundation

public let defaultURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
public let defaultAppId = "685343"
public let defaultNamespace = "ASR"
public let defaultProtoVersion = "v2"
public let defaultCodec = "speech_opus"
public let defaultListenHost = "127.0.0.1"
public let defaultListenPort: UInt16 = 47800
// Supply service credentials explicitly; the distributed module includes none.
public let defaultAppKey = ""
public let defaultContextAppKey = ""
public let defaultApiAccessKey = ""
// Frontier requires a positive Int64 device_id; empty/"0" → 40200001.
public let defaultDeviceId = ""
public let observedWSSURLs = [
    defaultURL,
    "wss://frontier-audio-ime-quic.doubao.com/api/v1/ws",
    "wss://frontier-ime.doubao.com/ws/v2",
]

public let envMap: [(field: String, env: String)] = [
    ("url", "TYPELESS_ASR_URL"),
    ("app_key", "TYPELESS_ASR_APP_KEY"),
    ("token", "TYPELESS_ASR_TOKEN"),
    ("device_id", "TYPELESS_ASR_DEVICE_ID"),
    ("app_id", "TYPELESS_ASR_APP_ID"),
    ("namespace", "TYPELESS_ASR_NAMESPACE"),
    ("proto_version", "TYPELESS_ASR_PROTO_VERSION"),
    ("iid", "TYPELESS_ASR_IID"),
    ("input_mode", "TYPELESS_ASR_INPUT_MODE"),
    ("ss_dp", "TYPELESS_ASR_SS_DP"),
]
public let configPathEnv = "TYPELESS_CONFIG"
public let sessionPathEnv = "TYPELESS_SESSION"

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let m): return m } }
}

public enum FinishMode: String, Sendable {
    /// Spec §15.1: hold the latest packet so the last real audio packet carries finish_audio.
    case pending
    /// Experimental: send every packet immediately; finish with an empty finish_audio TaskRequest.
    case eager
}

public struct ASRProfile: Equatable, Sendable {
    public var url = defaultURL
    public var appKey = defaultAppKey
    public var token = ""
    public var deviceId = defaultDeviceId
    public var appId = defaultAppId
    public var namespace = defaultNamespace
    public var protoVersion = defaultProtoVersion
    public var codec = defaultCodec
    public var sampleRate = 16000
    public var channels = 1
    public var bits = 16
    public var frameMs = 40
    public var twoPass = true
    public var threePass = false
    public var iid = ""
    public var inputMode = ""
    public var ssDp = ""
    public var startSessionExtra: JSONObject? = nil

    public init(url: String = defaultURL, appKey: String = defaultAppKey, token: String = "",
                deviceId: String = defaultDeviceId, appId: String = defaultAppId) {
        self.url = url
        self.appKey = appKey
        self.token = token
        self.deviceId = deviceId
        self.appId = appId
    }

    public func websocketURL() -> String {
        buildWSSURL(url, deviceId: deviceId, aid: appId, appkey: appKey)
    }

    /// Ordered header list (spec §10.2 + appkey + optional X-SS-DP).
    public func headers() -> [(String, String)] {
        var headers: [(String, String)] = [
            ("proto-version", protoVersion.isEmpty ? defaultProtoVersion : protoVersion),
            ("x-ttnet-protocol-handler", "1"),
            ("x-custom-keepalive", "true"),
            ("x-keepalive-interval", "3"),
            ("x-keepalive-timeout", "3600"),
        ]
        if !appKey.isEmpty {
            // Live Frontier StartSession requires appkey in header or query.
            headers.append(("appkey", appKey))
            headers.append(("x-api-app-key", appKey))
        }
        if !ssDp.isEmpty { headers.append(("X-SS-DP", ssDp)) }
        return headers
    }

    /// Apply a `field name → value` mapping (already alias-normalized). Unknown keys ignored.
    mutating func apply(_ data: [String: JSONValue]) {
        func str(_ v: JSONValue) -> String {
            switch v {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return pythonFloatRepr(d)
            case .bool(let b): return b ? "True" : "False"
            default: return v.compactJSON()
            }
        }
        func int(_ v: JSONValue, _ cur: Int) -> Int {
            if let i = v.intValue { return Int(i) }
            if let s = v.stringValue, let i = Int(s) { return i }
            return cur
        }
        func bool(_ v: JSONValue, _ cur: Bool) -> Bool {
            if let b = v.boolValue { return b }
            return v.pythonTruthy
        }
        for (key, value) in data where !value.isNull {
            switch key {
            case "url": url = str(value)
            case "app_key": appKey = str(value)
            case "token": token = str(value)
            case "device_id": deviceId = str(value)
            case "app_id": appId = str(value)
            case "namespace": namespace = str(value)
            case "proto_version": protoVersion = str(value)
            case "codec": codec = str(value)
            case "sample_rate": sampleRate = int(value, sampleRate)
            case "channels": channels = int(value, channels)
            case "bits": bits = int(value, bits)
            case "frame_ms": frameMs = int(value, frameMs)
            case "two_pass": twoPass = bool(value, twoPass)
            case "three_pass": threePass = bool(value, threePass)
            case "iid": iid = str(value)
            case "input_mode": inputMode = str(value)
            case "ss_dp": ssDp = str(value)
            case "start_session_extra": startSessionExtra = value.objectValue
            default: break
            }
        }
    }
}

// MARK: - URL query merge (urlsplit / parse_qsl / urlencode semantics)

struct SplitURL {
    var scheme = ""
    var netloc = ""
    var path = ""
    var query = ""
    var fragment = ""

    init(_ url: String) {
        var rest = Substring(url)
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        if let colon = rest.firstIndex(of: ":"), rest[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }), !rest[..<colon].isEmpty {
            scheme = String(rest[..<colon]).lowercased()
            rest = rest[rest.index(after: colon)...]
        }
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            if let slash = rest.firstIndex(of: "/") {
                netloc = String(rest[..<slash])
                rest = rest[slash...]
            } else {
                netloc = String(rest)
                rest = ""
            }
        }
        path = String(rest)
    }

    func unsplit() -> String {
        var out = ""
        if !scheme.isEmpty { out += scheme + ":" }
        if !netloc.isEmpty || scheme == "file" || (!scheme.isEmpty && path.hasPrefix("//")) { out += "//" + netloc }
        out += path
        if !query.isEmpty { out += "?" + query }
        if !fragment.isEmpty { out += "#" + fragment }
        return out
    }

    var host: String {
        var h = netloc
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if h.hasPrefix("[") { if let end = h.firstIndex(of: "]") { return String(h[h.index(after: h.startIndex)..<end]) } }
        if let colon = h.lastIndex(of: ":") { h = String(h[..<colon]) }
        return h
    }

    var port: Int? {
        var h = netloc
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if h.hasPrefix("["), let end = h.firstIndex(of: "]") { h = String(h[end...]) }
        if let colon = h.lastIndex(of: ":") { return Int(h[h.index(after: colon)...]) }
        return nil
    }
}

private func percentDecode(_ s: String, plusIsSpace: Bool) -> String {
    var bytes: [UInt8] = []
    let u = Array(s.utf8)
    var i = 0
    while i < u.count {
        let c = u[i]
        if c == UInt8(ascii: "+") && plusIsSpace { bytes.append(0x20); i += 1; continue }
        if c == UInt8(ascii: "%"), i + 2 < u.count, let hi = hexVal(u[i + 1]), let lo = hexVal(u[i + 2]) {
            bytes.append(hi << 4 | lo)
            i += 3
            continue
        }
        bytes.append(c)
        i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexVal(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

/// urllib.parse.quote_plus: alnum and `-_.` kept, space → `+`, else %XX (uppercase).
private func quotePlus(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
            out.unicodeScalars.append(Unicode.Scalar(b))
        case 0x20: out += "+"
        default: out += String(format: "%%%02X", b)
        }
    }
    return out
}

func parseQSL(_ query: String) -> [(String, String)] {
    if query.isEmpty { return [] }
    var out: [(String, String)] = []
    for part in query.split(separator: "&", omittingEmptySubsequences: true) {
        if let eq = part.firstIndex(of: "=") {
            out.append((percentDecode(String(part[..<eq]), plusIsSpace: true), percentDecode(String(part[part.index(after: eq)...]), plusIsSpace: true)))
        } else {
            out.append((percentDecode(String(part), plusIsSpace: true), ""))
        }
    }
    return out
}

func urlencode(_ pairs: [(String, String)]) -> String {
    pairs.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
}

public func mergeQuery(_ url: String, _ params: [(String, String)]) -> String {
    var parts = SplitURL(url)
    var merged = parseQSL(parts.query)
    // dict(parse_qsl(...)) keeps the last value for duplicate keys, first position.
    var dedup: [(String, String)] = []
    for (k, v) in merged {
        if let idx = dedup.firstIndex(where: { $0.0 == k }) { dedup[idx].1 = v } else { dedup.append((k, v)) }
    }
    merged = dedup
    let existing = Set(merged.map { $0.0 })
    for (key, value) in params {
        if value.isEmpty { continue }
        if existing.contains(key) { continue }
        merged.append((key, value))
    }
    parts.query = urlencode(merged)
    return parts.unsplit()
}

public func wssOriginPath(_ url: String) -> (String, String, String) {
    let p = SplitURL(url)
    return (p.scheme, p.netloc, p.path)
}

public func isObservedWSSURL(_ url: String) -> Bool {
    let key = wssOriginPath(url)
    return observedWSSURLs.contains { wssOriginPath($0) == key }
}

/// Merge device_id/aid/appkey onto any ASR WSS URL without duplicating existing keys.
public func buildWSSURL(_ url: String, deviceId: String = "", aid: String = "", appkey: String = "") -> String {
    mergeQuery(url, [("device_id", deviceId), ("aid", aid), ("appkey", appkey)])
}

// MARK: - Loading

private let fieldAliases: [String: String] = [
    "appkey": "app_key", "appKey": "app_key", "deviceId": "device_id", "appId": "app_id",
    "protoVersion": "proto_version", "enable_asr_twopass": "two_pass", "enable_asr_threepass": "three_pass",
    "did": "device_id", "wssUrl": "url", "inputMode": "input_mode", "ssDp": "ss_dp", "X-SS-DP": "ss_dp",
]

private let allowedFields: Set<String> = [
    "url", "app_key", "token", "device_id", "app_id", "namespace", "proto_version", "codec", "sample_rate",
    "channels", "bits", "frame_ms", "two_pass", "three_pass", "iid", "input_mode", "ss_dp", "start_session_extra",
]

public func fromMapping(_ data: [String: JSONValue]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (key, value) in data {
        let name = fieldAliases[key] ?? key
        if allowedFields.contains(name), !value.isNull { out[name] = value }
    }
    return out
}

public func fromMapping(_ obj: JSONObject) -> [String: JSONValue] {
    var dict: [String: JSONValue] = [:]
    for (k, v) in obj.pairs { dict[k] = v }
    return fromMapping(dict)
}

func modeIs0600(_ path: String) -> Bool {
    var st = stat()
    guard stat(path, &st) == 0 else { return false }
    return (st.st_mode & 0o777) == 0o600
}

public func loadLocalConfig(path: String?, env: [String: String]) throws -> [String: JSONValue] {
    let resolved = path ?? env[configPathEnv]
    guard let p = resolved, !p.isEmpty else { return [:] }
    let full = expandTilde(p)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else {
        throw ConfigError.message("config file not found: \(full)")
    }
    guard modeIs0600(full) else { throw ConfigError.message("config file must be mode 0600: \(full)") }
    let parsed = try JSONParser.parse(try readFile(path: full))
    guard let obj = parsed.objectValue else { throw ConfigError.message("config file must be a JSON object") }
    return fromMapping(obj)
}

public func loadEnvProfile(_ env: [String: String]) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    for (field, value) in envAliases(env) { out[field] = .string(value) }
    for (field, name) in envMap {
        if let v = env[name], !v.isEmpty { out[field] = .string(v) }
    }
    return out
}

public func processEnvironment() -> [String: String] { ProcessInfo.processInfo.environment }

/// `~/.config/typeless-engine/session.json` (or `$TYPELESS_SESSION`), written by the Python
/// `login` flow. Read-only; returns an empty object when absent or unparsable.
public func defaultSessionPath(env: [String: String] = processEnvironment()) -> String {
    if let p = env[sessionPathEnv], !p.isEmpty { return expandTilde(p) }
    return expandTilde("~/.config/typeless-engine/session.json")
}

public func loadSession(path: String? = nil, env: [String: String] = processEnvironment()) -> JSONObject {
    let p = path ?? defaultSessionPath(env: env)
    guard FileManager.default.isReadableFile(atPath: p), let bytes = try? readFile(path: p),
          let parsed = try? JSONParser.parse(bytes), let obj = parsed.objectValue else { return JSONObject() }
    return obj
}

/// Best-effort ASR token from the saved session: the Python login flow only persists
/// `token_present`, so this returns "" unless a future flow stores `token`/`asr_token`.
public func sessionToken(_ session: JSONObject) -> String {
    for key in ["asr_token", "token"] {
        if let s = session[key]?.stringValue, !s.isEmpty { return s }
    }
    return ""
}

public func loadProfile(args: [String: JSONValue] = [:], env: [String: String]? = nil, configPath: String? = nil,
                        captureProfile: [String: JSONValue]? = nil, useSessionFile: Bool = true) throws -> ASRProfile {
    let environment = env ?? processEnvironment()
    var profile = ASRProfile()
    if let capture = captureProfile { profile.apply(fromMapping(capture)) }
    profile.apply(try loadLocalConfig(path: configPath, env: environment))
    profile.apply(loadEnvProfile(environment))
    var cleaned: [String: JSONValue] = [:]
    for (k, v) in fromMapping(args) where !(v.isNull || v == .string("")) { cleaned[k] = v }
    profile.apply(cleaned)
    if useSessionFile, profile.token.isEmpty {
        let tok = sessionToken(loadSession(env: environment))
        if !tok.isEmpty { profile.token = tok }
    }
    return profile
}

public func validateListenHost(_ host: String?) throws -> String {
    var value = (host ?? defaultListenHost).trimmingCharacters(in: .whitespaces)
    if value.isEmpty { value = defaultListenHost }
    if ["0.0.0.0", "::", "[::]"].contains(value) {
        throw ConfigError.message("refusing to bind non-loopback; default is 127.0.0.1")
    }
    return value
}
