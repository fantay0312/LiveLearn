import Foundation
import TypelessCore

func runMain() -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    do {
        let args = try parseArgs(argv)
        if args.command.isEmpty || args.flag("help") {
            printOut(usageText)
            return args.command.isEmpty && !args.flag("help") ? 2 : 0
        }
        switch args.command {
        case "dump-proto": return try cmdDumpProto(args)
        case "encode-opus": return try cmdEncodeOpus(args)
        case "audio-format": return try cmdAudioFormat(args)
        case "export-defaults": return cmdExportDefaults()
        case "asr": return try cmdASR(args)
        case "mic": return try cmdMic(args)
        case "adapter": return try cmdAdapter(args)
        case "stdio": return try cmdStdio(args)
        case "bench": return try cmdBench(args)
        case "test-offline": return try cmdTestOffline(args)
        case "extract", "login", "logout", "ensure-did", "ime", "handshake", "replay-capture":
            printErr("error: '\(args.command)' is intentionally not ported; use the Python tool: " +
                     "PYTHONPATH=src python3 -m typeless_engine \(args.command) (see docs/MIGRATION.md)")
            return 2
        default:
            printErr("error: unknown command '\(args.command)'")
            printOut(usageText)
            return 2
        }
    } catch {
        printErr("error: \(error)")
        return 1
    }
}

exit(runMain())
