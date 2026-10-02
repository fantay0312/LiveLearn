// Subcommand implementations.
import Foundation
import Synchronization
import TypelessAudio
import TypelessCore
import TypelessNet

func cmdDumpProto(_ args: ParsedArgs) throws -> Int32 {
    guard let input = args.positionals.first else { throw CLIError("dump-proto requires FILE") }
    printOut(try dumpProto(try readFile(path: input)))
    return 0
}

func cmdEncodeOpus(_ args: ParsedArgs) throws -> Int32 {
    guard let input = args.positionals.first else { throw CLIError("encode-opus requires IN.wav") }
    guard let output = args.option("output") else { throw CLIError("encode-opus requires --output") }
    let count = try encodeWAVFile(input: input, output: output, pad: !args.flag("no-pad"))
    printOut("packets=\(count) bytes=\(count * 320) prefix=bb4201")
    return 0
}

func cmdAudioFormat(_ args: ParsedArgs) throws -> Int32 {
    printOut(audioFormat().compactJSON())
    return 0
}

func makeTransport(live: Bool, profile: ASRProfile, queue: DispatchQueue) -> ASRTransport {
    live ? LiveTransport(profile: profile, queue: queue) : MockTransport()
}

func cmdASR(_ args: ParsedArgs) throws -> Int32 {
    guard let input = args.positionals.first else { throw CLIError("asr requires IN.wav") }
    let (profile, live, _) = try runtimeProfile(args)
    let mode = try finishMode(args)
    let pcm = try readWAV(path: input)
    let queue = DispatchQueue(label: "typeless.asr", qos: .userInteractive)
    let transport = makeTransport(live: live, profile: profile, queue: queue)
    let timeout = try args.double("timeout", default: 15)
    let t0 = monotonicNanos()
    let result: TranscribeResult
    do {
        result = try transcribePCM(
            pcm, profile: profile, transport: transport, twoPass: !args.flag("one-pass"), threePass: args.flag("three-pass"),
            pad: true, finishMode: mode, realtimePacing: args.flag("realtime"), timeout: timeout,
            onTranscript: args.flag("verbose") ? { ev in printErr("transcript seq=\(ev.seqId) final=\(ev.isFinal) text=\(ev.text)") } : nil)
    } catch {
        throw CLIError("asr failed (mode=\(live ? "live" : "mock")): \(error)")
    }
    let total = Double(monotonicNanos() - t0) / 1e6
    if args.value("event-format", default: "engine") == "cometix" {
        let events = sessionToCometixEvents(taskId: result.taskId, transcripts: result.transcripts,
                                            remoteFinished: result.remoteFinished, mode: live ? "live" : "mock")
        printOut(JSONValue.array(events).compactJSON())
    } else {
        printOut(JSONValue.obj([("text", .string(result.text)), ("events", .int(Int64(result.transcripts.count)))]).compactJSON())
    }
    if args.flag("stats") {
        var stats = result.stats.objectValue!
        stats["mode"] = .string(live ? "live" : "mock")
        stats["finish_mode"] = .string(mode.rawValue)
        stats["wall_total_ms"] = .double((total * 1000).rounded() / 1000)
        if let lt = transport as? LiveTransport { stats["connect_ms"] = .double((lt.connectLatencyMs * 1000).rounded() / 1000) }
        printErr(JSONValue.object(stats).compactJSON())
    }
    return 0
}

func cmdMic(_ args: ParsedArgs) throws -> Int32 {
    if args.flag("list-devices") {
        let devices = AudioDevices.listInput()
        printOut(JSONValue.obj([("devices", .array(devices.enumerated().map { $0.element.json(index: $0.offset) }))]).compactJSON())
        return 0
    }
    let seconds = try args.double("seconds", default: 6)
    guard seconds > 0 else { throw CLIError("--seconds must be positive") }
    let (profile, live, _) = try runtimeProfile(args)
    let mode = try finishMode(args)
    let device = try AudioDevices.resolve(args.option("device"))
    let bufferFrames = UInt32(try args.int("buffer-frames", default: 256))
    let result = try runMicSession(profile: profile, device: device, seconds: seconds, live: live, finishMode: mode,
                                   bufferFrames: bufferFrames, speak: args.option("speak"), verbose: args.flag("verbose"))
    printOut(result.output.compactJSON())
    if args.flag("stats") { printErr(result.stats.compactJSON()) }
    return 0
}

struct MicRunResult {
    var output: JSONValue
    var stats: JSONValue
}

func runMicSession(profile: ASRProfile, device: AudioDeviceInfo, seconds: Double, live: Bool, finishMode: FinishMode,
                   bufferFrames: UInt32, speak: String?, verbose: Bool) throws -> MicRunResult {
    let queue = DispatchQueue(label: "typeless.mic.engine", qos: .userInteractive)
    let transport = makeTransport(live: live, profile: profile, queue: queue)
    let engine = try CoreEngine(profile: profile, transport: transport, queue: queue, finishMode: finishMode)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var failure: ASRSessionError? = nil
    var partials: [String] = []
    var finalText = ""
    engine.session.onStarted = { started.signal() }
    engine.session.onFinished = { finished.signal() }
    engine.session.onTranscript = { ev in
        engine.noteTranscript()
        lock.lock()
        if !ev.text.isEmpty { partials.append(ev.text) }
        finalText = ev.text
        lock.unlock()
        if verbose { printErr("transcript seq=\(ev.seqId) final=\(ev.isFinal) text=\(ev.text)") }
    }
    engine.session.onError = { err in
        lock.lock(); failure = err; lock.unlock()
        started.signal(); finished.signal()
    }
    let payload = buildStartSessionPayload(
        deviceId: profile.deviceId, appId: profile.appId, twoPass: profile.twoPass, threePass: profile.threePass,
        inputMode: profile.inputMode, iid: profile.iid, extraOverlay: profile.startSessionExtra)
    queue.async { engine.start(sessionPayload: payload) }
    guard started.wait(timeout: .now() + 15) == .success else { throw CLIError("timeout waiting for SessionStarted") }
    lock.lock(); let f1 = failure; lock.unlock()
    if let f1 = f1 { throw CLIError("session failed: \(f1.message)") }

    let capture = MicCapture(device: device, requestedBufferFrames: bufferFrames)
    try capture.start()
    let streamerEncoder = try SpeechOpusEncoder()
    var pushErrors = 0
    let streamer = try MicStreamer(capture: capture, encoder: streamerEncoder) { packet, captureNs, encodedNs in
        let copy = Array(packet)
        queue.async {
            do { try copy.withUnsafeBytes { try engine.pushPacket($0, encodedNs: encodedNs, captureNs: captureNs) } } catch {
                pushErrors += 1
            }
        }
    }
    streamer.start()
    // Count `seconds` from the first delivered IO buffer (AUHAL start-up is ~50–100 ms).
    let firstCallbackDeadline = Date().addingTimeInterval(2)
    while capture.callbacks.load(ordering: .relaxed) == 0 && Date() < firstCallbackDeadline { usleep(1000) }
    let startedAt = Date()
    var speaker: Process? = nil
    while Date().timeIntervalSince(startedAt) < seconds {
        usleep(20_000)
        if let text = speak, speaker == nil, Date().timeIntervalSince(startedAt) >= 0.4 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = [text]
            try? p.run()
            speaker = p
        }
        lock.lock(); let failed = failure != nil; lock.unlock()
        if failed { break }
    }
    streamer.stop()
    _ = streamer.flushPending()
    capture.stop()
    if let p = speaker, p.isRunning { p.waitUntilExit() }
    var finishError: Error? = nil
    queue.sync { do { try engine.finish() } catch { finishError = error } }
    if let e = finishError { throw CLIError("finish failed: \(e)") }
    _ = finished.wait(timeout: .now() + 15)
    lock.lock(); let f2 = failure; lock.unlock()
    let micStats = streamer.snapshot()
    var stats = queue.sync { engine.statsJSON().objectValue! }
    stats["mode"] = .string(live ? "live" : "mock")
    stats["finish_mode"] = .string(finishMode.rawValue)
    stats["device"] = .string(device.name)
    stats["device_rate"] = .double(micStats.deviceRate)
    stats["io_buffer_frames"] = .int(Int64(micStats.bufferFrames))
    stats["io_buffer_ms"] = .double(micStats.deviceRate > 0 ? (Double(micStats.bufferFrames) / micStats.deviceRate * 1000 * 1000).rounded() / 1000 : 0)
    stats["io_callbacks"] = .int(Int64(micStats.callbacks))
    stats["ring_overruns"] = .int(Int64(micStats.overruns))
    stats["render_errors"] = .int(Int64(micStats.renderErrors))
    stats["realtime_policy"] = .bool(micStats.realtimePolicy)
    stats["capture_to_packet_ms"] = micStats.captureToPacket.summary()
    stats["push_errors"] = .int(Int64(pushErrors))
    if let lt = transport as? LiveTransport { stats["connect_ms"] = .double((lt.connectLatencyMs * 1000).rounded() / 1000) }
    if let f2 = f2 { stats["error"] = .string(f2.message) }
    queue.sync { engine.close() }
    let output = JSONValue.obj([
        ("device", .string(device.uid.isEmpty ? device.name : device.uid)),
        ("device_name", .string(device.name)),
        ("seconds", .double(seconds)),
        ("frames", .int(Int64(micStats.packets))),
        ("mode", .string(live ? "live" : "mock")),
        ("text", .string(finalText)),
        ("partials", .array(partials.map { .string($0) })),
    ])
    return MicRunResult(output: output, stats: .object(stats))
}

func cmdAdapter(_ args: ParsedArgs) throws -> Int32 {
    let host = try validateListenHost(args.option("listen-host"))
    let port = UInt16(try args.int("listen-port", default: Int(defaultListenPort)))
    let (profile, live, _) = try runtimeProfile(args)
    let mode = try finishMode(args)
    let server = try AdapterServer(host: host, port: port, profile: profile, live: live, finishMode: mode)
    if args.flag("verbose") { server.log = { printErr($0) } }
    try server.start()
    printOut("adapter listen=\(host):\(server.boundPort) mock=\(!live) finish_mode=\(mode.rawValue)")
    signal(SIGINT) { _ in exit(130) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()
}

func cmdTestOffline(_ args: ParsedArgs) throws -> Int32 {
    runSelfChecks(verbose: true) ? 0 : 1
}
