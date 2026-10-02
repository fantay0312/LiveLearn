import Foundation
import AVFoundation
import AudioDomain
import CaptionDomain
import ProviderAdapters
import SessionDomain
import SessionStorage
import LocalEngine
import WhisperEngine

/// `LiveLearn --probe whisper:<variant>`: downloads a WhisperKit model into the app's model
/// folder and loads it once, printing progress. The same path the 本地模型 page uses.
@MainActor
enum WhisperProbe {
    static func run(spec: String) async -> Int32 {
        func line(_ s: String) { print("[whisper] \(s)"); fflush(stdout) }
        let id = String(spec.dropFirst("whisper:".count))
        guard WhisperVariant.named(id) != nil else {
            line("unknown variant \(id); known: \(WhisperVariant.all.map(\.id).joined(separator: ", "))")
            return 2
        }
        if WhisperModelStore.isInstalled(id) {
            line("already installed at \(WhisperModelStore.folder(for: id).path)")
        } else {
            line("downloading \(id) to \(WhisperModelStore.downloadBase.path)")
            let box = ProgressBox()
            let poll = Task {
                while !Task.isCancelled {
                    line("progress \(Int(box.value * 100))%")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            do {
                let url = try await WhisperModelStore.download(id) { box.value = $0 }
                poll.cancel()
                line("downloaded to \(url.path)")
            } catch {
                poll.cancel()
                line("download failed: \(error)")
                return 3
            }
        }
        let started = Date()
        do {
            try await WhisperModelStore.prepare(id)
            line("prepared (loaded + compiled) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            line("prepare failed: \(error)")
            return 3
        }
        line("installed bytes \(WhisperModelStore.installedBytes(id))")
        return 0
    }
}

/// A progress value written from a download callback and read by a polling task.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v = 0.0
    var value: Double {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}

/// `LiveLearn --probe engine:<source>><target>:<audio file>`
///
/// Runs the production session chain (lane coordinator → resampling adapter → local engine →
/// reducer → archive → export) with an audio file standing in for the capture device, in real
/// time. Proves recognition and translation without a microphone, a process tap or a consent
/// dialog; prints every finalized sentence as it lands and writes the archive plus an SRT next
/// to the input file.
@MainActor
enum EngineProbe {
    static func run(spec: String) async -> Int32 {
        func line(_ s: String) { print("[engine] \(s)"); fflush(stdout) }
        // engine:en>zh-Hans:/path/to/file.aiff
        let parts = spec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "engine" else {
            line("usage: --probe engine:<source>><target>:<audio file>")
            return 2
        }
        let langs = parts[1].split(separator: ">").map(String.init)
        guard langs.count == 2 else { line("bad language pair \(parts[1])"); return 2 }
        let url = URL(fileURLWithPath: parts[2])
        guard FileManager.default.fileExists(atPath: url.path) else { line("no such file \(url.path)"); return 2 }

        // The engine is whatever Settings says (Apple + Apple by default), so the probe also
        // exercises a cloud stage once the user has configured and keyed it. Tests point it at
        // their own defaults suite with LIVELEARN_DEFAULTS_SUITE so the user's settings stay put.
        let suite = ProcessInfo.processInfo.environment["LIVELEARN_DEFAULTS_SUITE"]
        let settings = suite.flatMap { UserDefaults(suiteName: $0) }.map { AppSettings(defaults: $0) } ?? AppSettings()
        let blueprint = EngineBlueprint(settings: settings, credentials: EngineCredentials.load())
        let source: String? = langs[0] == LanguageCatalog.auto ? nil : langs[0]
        let readiness = await blueprint.readiness(source: source, target: langs[1])
        line("engine \(blueprint.summary) · \(blueprint.dataDestination)")
        line("readiness \(langs[0])→\(langs[1]): recognizer \(readiness.recognizer.isReady ? "ready" : "blocked"), translator \(readiness.translator.isReady ? "ready" : "blocked")")
        if let blocker = readiness.blocker { line("blocked: \(blocker)"); return 3 }

        let anchor = MonotonicClock.nowNs()
        let capture = FileCapture(laneID: "remote", sessionAnchorNs: anchor, url: url)
        let coordinator = SessionCoordinator(sessionID: "engine-probe-\(Int(Date().timeIntervalSince1970))")
        let factories = LaneFactories(
            makeCapture: { _ in capture },
            makeProvider: { _ in try blueprint.makeProvider() }
        )
        let lane = LaneConfiguration(id: "remote", source: AudioSourceDescriptor(kind: .system, displayName: url.lastPathComponent), sourceLanguage: source, targetLanguage: langs[1], providerID: EngineBlueprint.providerID)

        let printer = Task {
            var seenState: SessionState = .idle
            var reported: Set<String> = []
            var lastPartial: [String: String] = [:]
            for await snap in coordinator.snapshots {
                if snap.state != seenState {
                    seenState = snap.state
                    line("state \(snap.state.rawValue)\(snap.failure.map { " · \($0)" } ?? "")\(snap.lanes.first?.lastError.map { " · lane: \($0)" } ?? "")")
                }
                for seg in snap.captions.segments {
                    if seg.presentationState == .final || seg.presentationState == .frozen {
                        if !reported.contains(seg.id) {
                            reported.insert(seg.id)
                            let t = StatusCopy.timestamp(seg.startNs)
                            line("FINAL  [\(t)] \(seg.sourceText)")
                            line("       → \(seg.translation?.text ?? "（无译文）")\(seg.isIncomplete ? "  [未完成: \(seg.incompleteReason ?? "")]" : "")")
                        }
                    } else if lastPartial[seg.id] != seg.sourceText {
                        lastPartial[seg.id] = seg.sourceText
                        line("partial       \(seg.sourceText)\(seg.translation.map { "  ⇢ \($0.text)" } ?? "")")
                    }
                }
                if snap.state == .completed || snap.state == .failed { break }
            }
        }

        let started = Date()
        await coordinator.start(lanes: [lane], factories: factories)
        var snap = await coordinator.currentSnapshot
        if snap.state == .failed {
            line("start failed: \(snap.failure ?? "?")")
            printer.cancel()
            return 3
        }
        while !capture.finished, snap.state.isActive {
            try? await Task.sleep(nanoseconds: 200_000_000)
            snap = await coordinator.currentSnapshot
        }
        // Let the recognizer catch up with the tail before flushing.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let stopAt = Date()
        await coordinator.stop()
        line("stop took \(String(format: "%.2f", Date().timeIntervalSince(stopAt))) s; session \(String(format: "%.1f", Date().timeIntervalSince(started))) s wall")
        _ = await printer.value
        snap = await coordinator.currentSnapshot

        let archive = SessionArchive(snapshot: snap, title: "\(url.lastPathComponent) · \(StatusCopy.direction(langs[0], langs[1]))", startedAt: started, outcome: snap.state == .failed ? .failed : .completed, appVersion: AppModel.appVersion)
        line("segments \(archive.segmentCount) final, \(archive.incompleteCount) incomplete, gaps \(archive.gapCount), lane \(snap.lanes.first.map { "\($0.capture.state.rawValue)/\($0.providerLink.rawValue)" } ?? "-")\(snap.lanes.first?.lastError.map { " lastError=\($0)" } ?? "")")
        let store = SessionStore(directory: url.deletingLastPathComponent().appendingPathComponent("engine-probe", isDirectory: true))
        do {
            let saved = try store.save(archive)
            line("archive \(saved.path)")
            let srt = try store.export(archive, format: .srt, to: saved.deletingPathExtension().appendingPathExtension("srt"))
            line("srt \(srt.path)")
            let txt = try store.export(archive, format: .text, to: saved.deletingPathExtension().appendingPathExtension("txt"))
            line("txt \(txt.path)")
        } catch {
            line("save/export failed: \(error)")
        }
        return archive.segmentCount > 0 ? 0 : 4
    }
}

/// Feeds an audio file as if it were a capture device: 100 ms packets in real time, stamped on
/// the lane timeline, then idle until stopped.
final class FileCapture: AudioCapture, @unchecked Sendable {
    let laneID: String
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let anchor: Int64
    private let url: URL
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var done = false

    init(laneID: String, sessionAnchorNs: Int64, url: URL) {
        self.laneID = laneID
        self.anchor = sessionAnchorNs
        self.url = url
        var c: AsyncStream<CaptureEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    var finished: Bool { lock.withLock { done } }

    func prepare(_ source: AudioSourceDescriptor) async throws {}

    func start() async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let descriptor = AudioFormatDescriptor(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
        continuation.yield(.started(epoch: 1, format: descriptor))
        continuation.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: 1, state: .capturing, format: descriptor)))
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        let lane = laneID
        let cont = continuation
        let anchor = self.anchor
        let lock = self.lock
        task = Task.detached { [self] in
            var timeline = LaneTimeline(sessionAnchorNs: anchor, captureEpoch: 1, sampleRate: format.sampleRate)
            var seq: UInt64 = 0
            var callbacks: UInt64 = 0
            while !Task.isCancelled, file.framePosition < file.length {
                guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                let frames = Int(buf.frameLength)
                guard frames > 0, let data = buf.floatChannelData else { break }
                var channels: [[Float]] = []
                for c in 0..<Int(format.channelCount) {
                    channels.append(Array(UnsafeBufferPointer(start: data[c], count: frames)))
                }
                seq += 1
                callbacks += 1
                // A file has no hardware clock: stamp by frame count so the packets are
                // contiguous, the way a device delivers them.
                let stamp = timeline.stamp(frameCount: frames, hostNs: nil)
                cont.yield(.packet(AudioPacket(laneID: lane, captureEpoch: 1, sequence: seq, sourceStartNs: stamp.startNs, sourceEndNs: stamp.endNs, format: descriptor, samples: OwnedAudioBuffer(channels: channels), discontinuityBefore: stamp.discontinuityBefore)))
                if callbacks % 10 == 0 {
                    cont.yield(.health(CaptureHealth(laneID: lane, captureEpoch: 1, state: .capturing, callbackCount: callbacks, format: descriptor)))
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            lock.withLock { self.done = true }
            cont.yield(.health(CaptureHealth(laneID: lane, captureEpoch: 1, state: .sourceIdle, callbackCount: callbacks, format: descriptor, detail: "文件已播完")))
        }
    }

    func stop() async {
        task?.cancel()
        continuation.yield(.stopped(epoch: 1))
    }
}
