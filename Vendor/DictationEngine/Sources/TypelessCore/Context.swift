// StartSession extra.context: prune, compact JSON, standard Base64 (spec §12, §12.1).
import Foundation

/// Drops null / "" / [] / {} recursively (dict and list members), like `prune_empty`.
public func pruneEmpty(_ value: JSONValue) -> JSONValue {
    func isEmptyish(_ v: JSONValue) -> Bool {
        switch v {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }
    switch value {
    case .object(let obj):
        var out = JSONObject()
        for (k, v) in obj.pairs {
            let pruned = pruneEmpty(v)
            if isEmptyish(pruned) { continue }
            out.pairs.append((k, pruned))
        }
        return .object(out)
    case .array(let items):
        return .array(items.map(pruneEmpty).filter { !isEmptyish($0) })
    default:
        return value
    }
}

public func encodeContextB64(_ context: JSONValue) -> String {
    let raw = pruneEmpty(context).compactJSONBytes()
    return Data(raw).base64EncodedString()
}

public func buildChatContext(text: String, cursor: Int, hostId: String, hotwords: [Hotword]) -> JSONValue {
    .obj([
        ("chatContext", .obj([
            ("data", .array([.obj([("cursorPosition", .int(Int64(cursor))), ("text", .string(text))])])),
            ("hostID", .string(hostId.isEmpty ? "EDITOR" : hostId)),
        ])),
        ("hotwordsInfo", .array(hotwords.filter { !$0.word.isEmpty }.map {
            .obj([("word", .string($0.word)), ("frequency", .int($0.frequency))])
        })),
    ])
}

public func buildStartSessionPayload(
    deviceId: String, appId: String, twoPass: Bool = true, threePass: Bool = false,
    context: JSONValue? = nil, inputMode: String = "", iid: String = "", extraOverlay: JSONObject? = nil
) -> [UInt8] {
    var extra = JSONObject([
        ("aid", .string(appId)),
        ("device_id", .string(deviceId)),
        ("did", .string(deviceId)),
        ("enable_text_filter", .bool(true)),
        ("remove_space_between_han_num", .bool(true)),
        ("remove_space_between_han_eng", .bool(true)),
    ])
    extra.update(frontierExtras(twoPass: twoPass, threePass: threePass, inputMode: inputMode, iid: iid, overlay: extraOverlay))
    if let context = context, context.pythonTruthy {
        extra["context"] = .string(encodeContextB64(context))
    }
    let body = JSONValue.obj([
        ("audio_info", .obj([
            ("format", .string("speech_opus")),
            ("sample_rate", .int(16000)),
            ("channel", .int(1)),
        ])),
        ("enable_punctuation", .bool(true)),
        ("enable_speech_rejection", .bool(false)),
        ("extra", .object(extra)),
    ])
    return body.compactJSONBytes()
}
