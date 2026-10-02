// `bench`: in-process micro and end-to-end measurements (Swift side of docs/BENCHMARK.md).
import Darwin
import Foundation
import TypelessCore
import TypelessNet

private func syntheticPCM(frames: Int, seed: UInt32 = 12345) -> [UInt8] {
    // Deterministic voice-like test signal: two tones + LCG noise, 40 ms frames.
    var out = [UInt8](repeating: 0, count: frames * frameBytes)
    var lcg = seed
    let total = frames * frameSamples
    out.withUnsafeMutableBytes { raw in
        for i in 0..<total {
            lcg = lcg &* 1664525 &+ 1013904223
            let noise = Double(Int32(bitPattern: lcg) >> 8) / Double(1 << 23) * 0.05
            let t = Double(i) / Double(sampleRate)
            let v = 0.3 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 1340 * t) + noise
            let s = Int16(max(-32768, min(32767, v * 32767)))
            raw.storeBytes(of: s.littleEndian, toByteOffset: i * 2, as: Int16.self)
        }
    }
    return out
}

private func series(_ samples: [UInt64]) -> LatencySeries {
    var s = LatencySeries()
    for v in samples { s.add(ns: v) }
    return s
}

private func microSummary(_ s: LatencySeries, unit: String = "us") -> JSONValue {
    let scale = unit == "us" ? 1000.0 : 1.0
    func r(_ v: Double) -> JSONValue { .double(((v * scale) * 1000).rounded() / 1000) }
    return .obj([
        ("count", .int(Int64(s.count))),
        ("p50_\(unit)", r(s.percentileMs(0.50))),
        ("p95_\(unit)", r(s.percentileMs(0.95))),
        ("p99_\(unit)", r(s.percentileMs(0.99))),
        ("mean_\(unit)", r(s.meanMs)),
    ])
}

private func processStartToNowMs() -> Double? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    var now = timeval()
    gettimeofday(&now, nil)
    let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6
    let current = Double(now.tv_sec) + Double(now.tv_usec) / 1e6
    return (current - start) * 1000
}

func residentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / 1048576
}

private func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 +
        Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

func cmdBench(_ args: ParsedArgs) throws -> Int32 {
    let startToMain = processStartToNowMs()
    let iterations = try args.int("iterations", default: 2000)
    let adapterIterations = try args.int("adapter-iterations", default: 250)
    let pcmChunk = try args.int("pcm-chunk", default: frameBytes)
    var report = JSONObject()
    report["opus_version"] = .string(opusVersionString())
    if let s = startToMain { report["process_start_to_main_ms"] = .double((s * 1000).rounded() / 1000) }

    // 1. Opus 40 ms packet encode
    let pcm = syntheticPCM(frames: 250)
    let encoder = try SpeechOpusEncoder()
    var packet = [UInt8](repeating: 0, count: speechOpusPacketBytes)
    var samples: [UInt64] = []
    samples.reserveCapacity(iterations)
    try pcm.withUnsafeBytes { raw in
        for i in 0..<iterations {
            let off = (i % 250) * frameBytes
            let frame = UnsafeRawBufferPointer(rebasing: raw[off..<off + frameBytes])
            let t0 = monotonicNanos()
            try packet.withUnsafeMutableBytes { try encoder.encode40ms(frame, into: $0) }
            samples.append(monotonicNanos() - t0)
        }
    }
    report["opus_encode_40ms"] = microSummary(series(samples))

    // 2. Envelope encode / decode (TaskRequest with a 320-byte packet)
    let meta = taskFrameMetadata(timestampMs: 1784527313513, finishAudio: false)
    let request = WebSocketRequest(namespace: "ASR", event: "TaskRequest", payload: meta, data: packet,
                                   taskId: "0F4C3B3E-2C7C-4C2C-9F0C-1B2E3D4F5A6B", seqId: 17)
    var writer = ProtoWriter(capacity: 512)
    let envIters = max(iterations * 25, 20000)
    samples.removeAll(keepingCapacity: true)
    for _ in 0..<envIters {
        let t0 = monotonicNanos()
        writer.reset()
        request.encode(into: &writer)
        samples.append(monotonicNanos() - t0)
    }
    report["envelope_encode"] = microSummary(series(samples))
    let encoded = writer.bytes
    let response = WebSocketResponse(taskId: request.taskId, namespace: "ASR", event: "ASRResponse", statusCode: 20000000,
                                     payload: Array("{\"results\":[{\"text\":\"模拟识别\",\"is_interim\":true,\"start_time\":0.0,\"end_time\":0.2,\"is_vad_finished\":false,\"extra\":{\"seq_id\":17}},{\"text\":\"模拟识别结果\",\"is_interim\":true,\"start_time\":0.0,\"end_time\":0.2,\"is_vad_finished\":false,\"extra\":{\"seq_id\":17}}],\"extra\":{\"seq_id\":17}}".utf8),
                                     seqId: 17).encode()
    samples.removeAll(keepingCapacity: true)
    for _ in 0..<envIters {
        let t0 = monotonicNanos()
        _ = try WebSocketRequest.decode(encoded)
        samples.append(monotonicNanos() - t0)
    }
    report["envelope_decode_request"] = microSummary(series(samples))
    samples.removeAll(keepingCapacity: true)
    for _ in 0..<envIters {
        let t0 = monotonicNanos()
        let r = try WebSocketResponse.decode(response)
        _ = try normalizePayload(r.payload, envelopeSeq: Int64(r.seqId))
        samples.append(monotonicNanos() - t0)
    }
    report["envelope_decode_response_plus_normalize"] = microSummary(series(samples))

    // 3. Full mock pipeline per 40 ms PCM frame (encode → envelope → mock remote → decode → normalize → event)
    let transport = MockTransport()
    transport.retainSent = false
    let engine = try CoreEngine(profile: ASRProfile(appKey: "k"), transport: transport)
    engine.session.retainHistory = false
    var transcripts = 0
    engine.session.onTranscript = { _ in transcripts += 1 }
    let cpu0 = cpuSeconds()
    let wall0 = monotonicNanos()
    engine.start(sessionPayload: buildStartSessionPayload(deviceId: "dev", appId: "685343"))
    samples.removeAll(keepingCapacity: true)
    let pipelineIters = max(iterations, 1000)
    try pcm.withUnsafeBytes { raw in
        for i in 0..<pipelineIters {
            let off = (i % 250) * frameBytes
            let frame = UnsafeRawBufferPointer(rebasing: raw[off..<off + frameBytes])
            let t0 = monotonicNanos()
            try engine.pushPCM40(frame)
            samples.append(monotonicNanos() - t0)
        }
    }
    try engine.finish()
    let wall = Double(monotonicNanos() - wall0) / 1e9
    let cpu = cpuSeconds() - cpu0
    engine.close()
    var pipeline = microSummary(series(samples)).objectValue!
    pipeline["transcripts"] = .int(Int64(transcripts))
    pipeline["cpu_seconds_per_hour_of_audio"] = .double(((cpu / (Double(pipelineIters) * 0.04) * 3600) * 1000).rounded() / 1000)
    pipeline["throughput_x_realtime"] = .double(((Double(pipelineIters) * 0.04 / wall) * 10).rounded() / 10)
    report["mock_pipeline_per_packet"] = .object(pipeline)

    // 4. Loopback Adapter round trip: PCM chunk in → interim event out (real TCP + WebSocket)
    let server = try AdapterServer(host: "127.0.0.1", port: 0, profile: ASRProfile(appKey: "k"))
    try server.start()
    defer { server.stop() }
    let client = LoopbackWSClient(url: URL(string: "ws://127.0.0.1:\(server.boundPort)/asr")!)
    try client.connect()
    let tConnect = monotonicNanos()
    client.sendText("{\"type\":\"start\",\"app\":\"bench\"}")
    guard let (_, readyPayload) = client.receive(timeout: 5), (try? JSONParser.parse(readyPayload))?["type"] == .string("ready") else {
        throw CLIError("adapter bench: no ready event")
    }
    let readyMs = Double(monotonicNanos() - tConnect) / 1e6
    let chunk = Array(pcm[0..<pcmChunk])
    // Prime: with the pending-last-packet policy the first frame produces no response, so a
    // chunk of k frames yields k-1 responses; drain them so the loop measures fresh events.
    client.sendBinary(chunk)
    var prime = pcmChunk / frameBytes - 1
    while prime > 0 { _ = client.receive(timeout: 2); prime -= 1 }
    samples.removeAll(keepingCapacity: true)
    var lost = 0
    for _ in 0..<adapterIterations {
        let t0 = monotonicNanos()
        client.sendBinary(chunk)
        guard let (kind, _) = client.receive(timeout: 5), kind == .text else { lost += 1; continue }
        samples.append(monotonicNanos() - t0)
        // Drain extra responses when a chunk carries several frames.
        var extra = pcmChunk / frameBytes - 1
        while extra > 0 { _ = client.receive(timeout: 2); extra -= 1 }
    }
    let tFinish = monotonicNanos()
    client.sendText("{\"type\":\"finish\"}")
    let finals = client.receiveEvents(until: "final", timeout: 10)
    let finalMs = Double(monotonicNanos() - tFinish) / 1e6
    client.close()
    var adapter = microSummary(series(samples), unit: "ms").objectValue!
    adapter["pcm_chunk_bytes"] = .int(Int64(pcmChunk))
    adapter["lost"] = .int(Int64(lost))
    adapter["start_to_ready_ms"] = .double((readyMs * 1000).rounded() / 1000)
    adapter["finish_to_final_ms"] = .double((finalMs * 1000).rounded() / 1000)
    adapter["final_received"] = .bool(finals.last?["type"] == .string("final"))
    report["adapter_loopback_rtt"] = .object(adapter)

    report["rss_mb"] = .double((residentMemoryMB() * 100).rounded() / 100)

    if args.flag("json") {
        printOut(JSONValue.object(report).compactJSON())
    } else {
        printOut("typeless-engine bench (Swift) — \(opusVersionString())")
        for (k, v) in report.pairs {
            if let obj = v.objectValue {
                printOut("  \(k): " + obj.pairs.map { "\($0.0)=\($0.1.compactJSON())" }.joined(separator: " "))
            } else {
                printOut("  \(k): \(v.compactJSON())")
            }
        }
    }
    return 0
}
