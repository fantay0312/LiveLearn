import Foundation
import TypelessCore

/// Exports built-in public defaults only; never loads environment, session files or login tokens.
func cmdExportDefaults() -> Int32 {
    let profile = ASRProfile()
    let defaults = JSONValue.obj([
        ("url", .string(profile.url)), ("app_id", .string(profile.appId)),
        ("device_id", .string(profile.deviceId)), ("app_key", .string(profile.appKey)),
        ("token_required", .bool(true)),
    ])
    FileHandle.standardOutput.write(Data(defaults.compactJSONBytes() + [10]))
    return 0
}
