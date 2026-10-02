// Cometix-asr protocol compatibility (no libcometix-asr*.node is ever loaded).
// Keys and event shapes come from ENGINE_REBUILD_SPEC plus the read-only cross-check
// documented in the Python tree's docs/cometix_compat.md.
import Foundation

public let cometixAudioEncoding = "linear16"
public let cometixReportedBitrate: Int64 = 64000

public let cometixEnvAliases: [(field: String, names: [String])] = [
    ("device_id", ["COMETIX_DEVICE_ID", "COMETIX_DID"]),
    ("iid", ["COMETIX_IID"]),
]

/// StartSession extra keys observed in cometix-asr, with values we can defend.
/// Numeric window/timeout fields are omitted unless the profile supplies them.
public let defaultFrontierExtras = JSONObject([
    ("asr_params", .obj([("enable_global_tracking", .bool(true))])),
    ("disable_user_words", .bool(false)),
    ("enable_print_chinese", .bool(true)),
    ("strong_ddc", .bool(true)),
    ("2a_send_enable", .bool(true)),
    ("2a_send_commands", .array([.string("帮我发送")])),
])

/// Same shape as cometix-asr `audioFormat()`; bitrate is the spec CBR (63600).
public func audioFormat() -> JSONValue {
    .obj([
        ("sampleRate", .int(Int64(sampleRate))),
        ("channels", .int(1)),
        ("frameSamples", .int(Int64(frameSamples))),
        ("frameBytes", .int(Int64(frameBytes))),
        ("encoding", .string(cometixAudioEncoding)),
        ("opusBitrate", .int(Int64(opusBitrate))),
    ])
}

/// Documented cometix-asr.audioFormat() probe (research, not encode params).
public func cometixAudioFormatProbe() -> JSONValue {
    var fmt = audioFormat().objectValue!
    fmt["opusBitrate"] = .int(cometixReportedBitrate)
    return .object(fmt)
}

public enum CometixError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { switch self { case .message(let m): return m } }
}

/// Map cometix SessionConfig JSON onto engine profile fields (string values only, plus
/// `start_session_extra` as an object).
public func parseSessionConfig(_ text: String?) throws -> [String: JSONValue] {
    guard let text = text, !text.isEmpty, text != "{}" else { return [:] }
    return try parseSessionConfig(try JSONParser.parse(text))
}

public func parseSessionConfig(_ value: JSONValue) throws -> [String: JSONValue] {
    guard let obj = value.objectValue else { throw CometixError.message("session config must be a JSON object") }
    let aliases: [(String, String)] = [
        ("did", "device_id"), ("deviceId", "device_id"), ("appKey", "app_key"), ("appkey", "app_key"),
        ("appId", "app_id"), ("wssUrl", "url"), ("url", "url"), ("inputMode", "input_mode"),
        ("input_mode", "input_mode"), ("enablePostAsr", "enable_post_asr"), ("enableFmt", "enable_fmt"),
        ("enableNer", "enable_ner"), ("mode", "mode"), ("context", "context_text"), ("samiToken", "sami_token"),
        ("iid", "iid"), ("appName", "app_name"), ("appVersion", "app_version"), ("token", "token"),
    ]
    var out: [String: JSONValue] = [:]
    for (key, mapped) in aliases {
        if let v = obj[key], !v.isNull, v != .string("") { out[mapped] = v }
    }
    if let extra = obj["extra"]?.objectValue { out["start_session_extra"] = .object(extra) }
    return out
}

/// Load an explicit cometix did.json. Never called unless the user points at it.
public func loadDidFile(path: String) throws -> [String: String] {
    let data = try JSONParser.parse(try readFile(path: expandTilde(path)))
    guard let obj = data.objectValue else { throw CometixError.message("did file must be a JSON object") }
    var out: [String: String] = [:]
    for key in ["did", "device_id", "deviceId"] {
        if let s = obj[key]?.stringValue, !s.isEmpty { out["device_id"] = s; break }
    }
    for key in ["iid", "install_id"] {
        if let s = obj[key]?.stringValue, !s.isEmpty { out["iid"] = s; break }
    }
    return out
}

public func envAliases(_ env: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    for (field, names) in cometixEnvAliases {
        for name in names {
            if let v = env[name], !v.isEmpty { out[field] = v; break }
        }
    }
    return out
}

public func frontierExtras(twoPass: Bool, threePass: Bool, inputMode: String = "", iid: String = "",
                           overlay: JSONObject? = nil) -> JSONObject {
    var extra = defaultFrontierExtras
    extra["use_twopass_retry"] = .bool(twoPass)
    if !inputMode.isEmpty { extra["input_mode"] = .string(inputMode) }
    if !iid.isEmpty { extra["iid"] = .string(iid) }
    if let overlay = overlay, !overlay.isEmpty { extra.update(overlay) }
    extra["enable_asr_twopass"] = .bool(twoPass)
    extra["enable_asr_threepass"] = .bool(threePass)
    return extra
}

public func cometixReady(sessionId: String, mode: String) -> JSONValue {
    .obj([("type", .string("ready")), ("session_id", .string(sessionId)), ("mode", .string(mode))])
}

public func cometixStage(_ event: TranscriptEvent, sessionFinal: Bool = false) -> String {
    if sessionFinal { return "session_final" }
    if event.isFinal || event.vadFinished { return "stable" }
    return "interim"
}

public func transcriptToCometix(_ event: TranscriptEvent, display: String? = nil, sessionFinal: Bool = false) -> JSONValue {
    let shown = display ?? event.text
    var body = JSONObject([
        ("type", .string("transcript")),
        ("text", .string(event.text)),
        ("is_final", .bool(sessionFinal || event.isFinal)),
        ("is_interim", .bool(!(sessionFinal || event.isFinal))),
        ("is_vad_finished", .bool(sessionFinal || event.vadFinished || event.isFinal)),
        ("display", .string(shown)),
        ("stage", .string(cometixStage(event, sessionFinal: sessionFinal))),
        ("pass_count", .int(Int64(max(event.resultCount, 1)))),
    ])
    if sessionFinal { body["stable_text"] = .string(shown) }
    return .object(body)
}

public func sessionToCometixEvents(taskId: String, transcripts: [TranscriptEvent], remoteFinished: Bool, mode: String) -> [JSONValue] {
    var events = [cometixReady(sessionId: taskId, mode: mode)]
    for (index, event) in transcripts.enumerated() {
        let sessionFinal = remoteFinished && index == transcripts.count - 1
        events.append(transcriptToCometix(event, sessionFinal: sessionFinal))
    }
    events.append(.obj([("type", .string("close"))]))
    return events
}

/// Additive ENGINE_API extras copied from the cometix transcript schema.
public func adapterCometixFields(_ event: TranscriptEvent, sessionFinal: Bool = false) -> JSONObject {
    var fields = JSONObject([
        ("stage", .string(cometixStage(event, sessionFinal: sessionFinal))),
        ("pass_count", .int(Int64(max(event.resultCount, 1)))),
        ("display", .string(event.text)),
        ("is_interim", .bool(!(sessionFinal || event.isFinal))),
        ("is_vad_finished", .bool(sessionFinal || event.vadFinished || event.isFinal)),
        ("pass", .string(passName(event.resultCount))),
    ])
    if sessionFinal { fields["stable_text"] = .string(event.text) }
    return fields
}
