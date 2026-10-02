// Hand-rolled argument parsing (no swift-argument-parser), mirroring the Python argparse flags.
import Foundation
import TypelessCore

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

struct ParsedArgs {
    var command: String = ""
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }
    func value(_ name: String, default def: String) -> String { options[name] ?? def }
    func int(_ name: String, default def: Int) throws -> Int {
        guard let raw = options[name] else { return def }
        guard let v = Int(raw) else { throw CLIError("--\(name) expects an integer, got '\(raw)'") }
        return v
    }
    func double(_ name: String, default def: Double) throws -> Double {
        guard let raw = options[name] else { return def }
        guard let v = Double(raw) else { throw CLIError("--\(name) expects a number, got '\(raw)'") }
        return v
    }
}

/// Options that take a value (everything else starting with `--` is a boolean flag).
let valueOptions: Set<String> = [
    "output", "event-format", "session-config", "did-file", "url", "app-key", "token", "device-id", "app-id",
    "config", "seconds", "device", "speak", "listen-host", "listen-port", "finish-mode", "iterations",
    "buffer-frames", "timeout", "adapter-iterations", "pcm-chunk",
]

func parseArgs(_ argv: [String]) throws -> ParsedArgs {
    var out = ParsedArgs()
    var i = 0
    if i < argv.count, !argv[i].hasPrefix("-") {
        out.command = argv[i]
        i += 1
    }
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            var name = String(a.dropFirst(2))
            var inlineValue: String? = nil
            if let eq = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if valueOptions.contains(name) {
                if let v = inlineValue {
                    out.options[name] = v
                } else {
                    i += 1
                    guard i < argv.count else { throw CLIError("--\(name) requires a value") }
                    out.options[name] = argv[i]
                }
            } else {
                out.flags.insert(name)
            }
        } else if a == "-h" {
            out.flags.insert("help")
        } else {
            out.positionals.append(a)
        }
        i += 1
    }
    return out
}

let usageText = """
usage: typeless-engine <command> [options]

commands:
  export-defaults                    export built-in public defaults only, without login credentials
  stdio --live|--mock                private JSON-lines parent/child channel; no config inheritance
  dump-proto FILE                     print protobuf field numbers without secrets
  encode-opus IN.wav --output OUT.bin [--no-pad]
                                      encode wav to concatenated 320-byte speech_opus
  audio-format                        PCM/Opus format (cometix audioFormat shape)
  asr IN.wav [--live] [--one-pass] [--three-pass] [--event-format engine|cometix]
             [--session-config JSON] [--did-file did.json] [--stats] [--realtime]
             [--finish-mode pending|eager] [profile options]
                                      transcribe a wav (mock by default)
  mic --list-devices                  enumerate CoreAudio input devices
  mic [--seconds N] [--device SPEC] [--live] [--speak TEXT] [--stats] [--buffer-frames N]
      [--finish-mode pending|eager] [profile options]
                                      stream the microphone to ASR and print events + latency
  adapter [--listen-host H] [--listen-port P] [--live] [--session-config JSON]
          [--did-file did.json] [--finish-mode pending|eager] [profile options]
                                      loopback ENGINE_API adapter (GET /health, WS /asr)
  bench [--iterations N] [--adapter-iterations N] [--json]
                                      in-process micro/end-to-end benchmarks
  test-offline                        run the §28.1 MUST self-checks

profile options: --url --app-key --token --device-id --app-id --config PATH
env: TYPELESS_ASR_URL/APP_KEY/TOKEN/DEVICE_ID/APP_ID/NAMESPACE/PROTO_VERSION/IID/INPUT_MODE/SS_DP,
     TYPELESS_CONFIG (JSON, mode 0600), TYPELESS_SESSION, COMETIX_DEVICE_ID/COMETIX_DID/COMETIX_IID
Real Doubao WSS only with --live; the default is the offline mock.
"""

func printOut(_ s: String) {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// `_runtime_profile`: session-config/did-file mapping + explicit args → load_profile; `mode` in
/// the session config can force live/mock.
func runtimeProfile(_ args: ParsedArgs) throws -> (ASRProfile, Bool, [String: JSONValue]) {
    var mapped: [String: JSONValue] = [:]
    if let sc = args.option("session-config") {
        for (k, v) in try parseSessionConfig(sc) { mapped[k] = v }
    }
    if let did = args.option("did-file") {
        for (k, v) in try loadDidFile(path: did) { mapped[k] = .string(v) }
    }
    var merged: [String: JSONValue] = [:]
    let passthrough: Set<String> = ["url", "app_key", "token", "device_id", "app_id", "iid", "input_mode", "start_session_extra"]
    for (k, v) in mapped where passthrough.contains(k) && !(v.isNull || v == .string("")) { merged[k] = v }
    let explicit: [(String, String)] = [("url", "url"), ("app_key", "app-key"), ("token", "token"), ("device_id", "device-id"), ("app_id", "app-id")]
    for (field, opt) in explicit {
        if let v = args.option(opt), !v.isEmpty { merged[field] = .string(v) }
    }
    let profile = try loadProfile(args: merged, configPath: args.option("config"))
    var live = args.flag("live")
    if let mode = mapped["mode"]?.stringValue {
        if mode == "live" { live = true } else if mode == "mock" { live = false }
    }
    return (profile, live, mapped)
}

func finishMode(_ args: ParsedArgs) throws -> FinishMode {
    let raw = args.value("finish-mode", default: "pending")
    guard let mode = FinishMode(rawValue: raw) else { throw CLIError("--finish-mode must be pending or eager") }
    return mode
}
