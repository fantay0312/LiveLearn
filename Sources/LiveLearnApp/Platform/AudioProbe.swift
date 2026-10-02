import Foundation
import AppKit
import AudioDomain
import MacAudio

/// `LiveLearn --probe <mic|system|app:<bundle id>|apps> [seconds]`
///
/// The first work package of doc §19.2: prove each capture path delivers real callbacks with a
/// real format and level, from inside the signed .app, and print what actually happened.
/// Output goes to stdout; nothing is uploaded, nothing is saved.
@MainActor
enum AudioProbe {
    static func run(target: String, seconds: Int) async -> Int32 {
        func line(_ s: String) { print("[probe] \(s)"); fflush(stdout) }
        line("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · bundle \(Bundle.main.bundleIdentifier ?? "?")")

        if target == "apps" {
            let apps = ApplicationAudioIdentityResolver.candidateApplications()
            line("\(apps.count) regular applications; audio processes: \(AudioProcessRegistry.allProcesses().count)")
            for app in apps {
                let m = ApplicationAudioIdentityResolver.resolve(bundleIdentifier: app.bundleIdentifier)
                line(String(format: "%@ %-40@ pid %6d  audio objects %2d  output %@", app.isPlayingAudio ? "▶" : " ", app.bundleIdentifier, app.pid, m.memberObjectIDs.count, m.anyOutputRunning ? "running" : "idle"))
            }
            for p in AudioProcessRegistry.allProcesses() where p.isRunningOutput {
                line("  output-running process object \(p.objectID) pid \(p.pid) \(p.bundleID ?? "-")")
            }
            return 0
        }

        let anchor = MonotonicClock.nowNs()
        let source: AudioSourceDescriptor
        let capture: any AudioCapture
        switch target {
        case "mic":
            let mic = AudioDeviceList.inputDevices().first { $0.isDefault }
            source = AudioSourceDescriptor(kind: .microphone, deviceUID: mic?.uid, displayName: mic?.name ?? "默认麦克风")
            capture = MicrophoneCapture(laneID: "probe", sessionAnchorNs: anchor)
            line("microphone permission before: \(MicrophoneCapture.authorizationStatus.rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
            line("input devices: \(AudioDeviceList.inputDevices().map { "\($0.name)\($0.isDefault ? "*" : "") @\(Int($0.sampleRate))" })")
        case "system":
            source = .system
            capture = ProcessTapCapture(laneID: "probe", sessionAnchorNs: anchor)
        default:
            guard target.hasPrefix("app:") || target.hasPrefix("pid:") else {
                line("unknown target \(target)")
                return 2
            }
            // "pid:<n>" is kept verbatim as the identity; the resolver understands it.
            // "app:a+b" ticks several applications into one mixed tap, as the sidebar does.
            let bids = (target.hasPrefix("app:") ? String(target.dropFirst(4)) : target).split(separator: "+").map(String.init)
            let m = ApplicationAudioIdentityResolver.resolve(bundleIdentifiers: bids)
            line("resolve \(bids.joined(separator: "+")): running \(m.isRunning), roots \(m.rootPIDs), members \(m.memberObjectIDs) pids \(m.memberPIDs), outputRunning \(m.anyOutputRunning)")
            source = AudioSourceDescriptor(kind: .application, bundleIdentifier: bids.first, displayName: AudioSourceDescriptor.applicationsLabel(bids), bundleIdentifiers: bids)
            capture = ProcessTapCapture(laneID: "probe", sessionAnchorNs: anchor)
        }

        let stats = ProbeStats()
        let consumer = Task {
            for await event in capture.events {
                switch event {
                case .started(let epoch, let format):
                    line("started epoch \(epoch) format \(format.summary) interleaved \(format.isInterleaved)")
                case .packet(let p):
                    stats.note(p)
                case .gap(let g):
                    line("GAP \(g.reason.rawValue) \(Double(g.durationNs) / 1e6) ms at \(Double(g.startNs) / 1e9)s")
                case .health(let h):
                    line("health \(h.state.rawValue) \(h.detail ?? "")")
                case .stopped(let epoch):
                    line("stopped epoch \(epoch)")
                case .failed(let f):
                    line("FAILED \(f.kind.rawValue): \(f.message) code \(f.code.map(String.init) ?? "-")")
                }
            }
        }

        do {
            line("prepare \(source.tag)")
            try await capture.prepare(source)
            line("start")
            try await capture.start()
        } catch let f as CaptureFailure {
            line("FAILED \(f.kind.rawValue): \(f.message) code \(f.code.map(String.init) ?? "-")")
            consumer.cancel()
            return 3
        } catch {
            line("FAILED \(error)")
            consumer.cancel()
            return 3
        }

        for second in 1...max(1, seconds) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let s = stats.snapshot()
            line(String(format: "t=%2ds packets %6d  frames %9d  rms %.4f  peak %.3f  last end %.2fs  discontinuities %d", second, s.packets, s.frames, s.rms, s.peak, Double(s.lastEndNs) / 1e9, s.discontinuities))
        }
        line("stop")
        await capture.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()
        let s = stats.snapshot()
        line("summary: packets \(s.packets) frames \(s.frames) maxPeak \(s.maxPeak) energyPackets \(s.energyPackets)")
        return s.packets > 0 ? 0 : 4
    }
}

private final class ProbeStats: @unchecked Sendable {
    struct Snapshot {
        var packets = 0
        var frames = 0
        var rms: Float = 0
        var peak: Float = 0
        var maxPeak: Float = 0
        var lastEndNs: Int64 = 0
        var discontinuities = 0
        var energyPackets = 0
    }
    private let lock = NSLock()
    private var s = Snapshot()

    func note(_ p: AudioPacket) {
        let e = p.samples.energy()
        lock.withLock {
            s.packets += 1
            s.frames += p.samples.frameCount
            s.rms = e.rms
            s.peak = e.peak
            s.maxPeak = max(s.maxPeak, e.peak)
            s.lastEndNs = p.sourceEndNs
            if p.discontinuityBefore { s.discontinuities += 1 }
            if AudioLevel.isAudible(rms: e.rms) { s.energyPackets += 1 }
        }
    }

    func snapshot() -> Snapshot { lock.withLock { s } }
}
