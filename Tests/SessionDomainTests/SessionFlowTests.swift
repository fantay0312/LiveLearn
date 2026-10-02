import Testing
import Foundation
@testable import AudioDomain
@testable import CaptionDomain
@testable import ProviderAdapters
@testable import SessionDomain

/// Synthetic capture: emits 100 ms packets of a quiet tone on a timer. No hardware, no TCC.
final class ToneCapture: AudioCapture, @unchecked Sendable {
    let laneID: String
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var task: Task<Void, Never>?
    private let anchor: Int64
    let amplitude: Float

    init(laneID: String, sessionAnchorNs: Int64, amplitude: Float = 0.1) {
        self.laneID = laneID
        self.anchor = sessionAnchorNs
        self.amplitude = amplitude
        var c: AsyncStream<CaptureEvent>.Continuation!
        events = AsyncStream { c = $0 }
        continuation = c
    }

    func prepare(_ source: AudioSourceDescriptor) async throws {}

    func start() async throws {
        let format = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
        continuation.yield(.started(epoch: 1, format: format))
        var timeline = LaneTimeline(sessionAnchorNs: anchor, captureEpoch: 1, sampleRate: 16_000)
        let amp = amplitude
        let lane = laneID
        let cont = continuation
        task = Task {
            var seq: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                seq += 1
                let frames = 1600
                let samples = (0..<frames).map { i in amp * sin(Float(i) * 0.1) }
                let stamp = timeline.stamp(frameCount: frames, hostNs: MonotonicClock.nowNs())
                cont.yield(.packet(AudioPacket(laneID: lane, captureEpoch: 1, sequence: seq, sourceStartNs: stamp.startNs, sourceEndNs: stamp.endNs, format: format, samples: OwnedAudioBuffer(mono: samples), discontinuityBefore: stamp.discontinuityBefore)))
            }
        }
    }

    func stop() async {
        task?.cancel()
        continuation.yield(.stopped(epoch: 1))
    }
}

@Suite("Session flow (synthetic capture + scripted provider)")
struct SessionFlowTests {

    @Test("Start → captions arrive → pause records a gap → stop drains to completed", .timeLimit(.minutes(1)))
    func endToEnd() async throws {
        let coordinator = SessionCoordinator(sessionID: "flow")
        let anchor = MonotonicClock.nowNs()
        var script = FakeScript.lecture(sentences: [
            FakeSentence("Please do not restart the server yet.", "请先不要重启服务器。"),
            FakeSentence("Thank you.", "谢谢。"),
        ], startMs: 50, translationDelayMs: 60, wordIntervalMs: 20, pauseBetweenMs: 60)
        // Keep the engine open so the test controls the stop.
        script.steps.removeAll { if case .end = $0 { return true } else { return false } }
        let openScript = script
        let factories = LaneFactories(
            makeCapture: { cfg in ToneCapture(laneID: cfg.id, sessionAnchorNs: anchor) },
            makeProvider: { _ in FakeProvider(script: openScript) }
        )
        let lane = LaneConfiguration(id: "remote", source: .system, sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "fake.demo")

        let collector = Task<[SessionSnapshot], Never> {
            var out: [SessionSnapshot] = []
            for await s in coordinator.snapshots {
                out.append(s)
                if s.state == .completed { break }
            }
            return out
        }

        await coordinator.start(lanes: [lane], factories: factories)
        #expect(await coordinator.currentSnapshot.state == .running)

        // Wait until both sentences are final with translations.
        var deadline = MonotonicClock.nowNs() + 5_000_000_000
        while MonotonicClock.nowNs() < deadline {
            let snap = await coordinator.currentSnapshot
            let finals = snap.captions.segments.filter { $0.presentationState == .final }
            if finals.count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var snap = await coordinator.currentSnapshot
        let finals = snap.captions.segments.filter { $0.presentationState == .final }
        #expect(finals.count == 2, "expected two final segments, got \(snap.captions.segments.map(\.presentationState))")
        #expect(finals.first?.translation?.text == "请先不要重启服务器。")
        #expect(snap.lanes.first?.capture.state == .capturing)
        #expect((snap.lanes.first?.capture.callbackCount ?? 0) > 3)
        #expect((snap.lanes.first?.capture.level ?? 0) > 0.01)

        await coordinator.pause()
        #expect(await coordinator.currentSnapshot.state == .paused)
        try await Task.sleep(nanoseconds: 250_000_000)
        await coordinator.resume()
        #expect(await coordinator.currentSnapshot.state == .running)
        deadline = MonotonicClock.nowNs() + 2_000_000_000
        while MonotonicClock.nowNs() < deadline {
            snap = await coordinator.currentSnapshot
            if snap.captions.items.contains(where: { if case .gap(let g) = $0 { return g.reason == GapReason.paused.rawValue } else { return false } }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let gaps = snap.captions.items.compactMap { if case .gap(let g) = $0 { return g } else { return nil } }
        #expect(gaps.contains { $0.reason == GapReason.paused.rawValue && $0.durationNs >= 200_000_000 })

        await coordinator.stop()
        let final = await coordinator.currentSnapshot
        #expect(final.state == .completed)
        #expect(final.lanes.first?.providerLink == .closed)
        #expect(final.lanes.first?.capture.state == .stopped)
        let history = await collector.value
        let states: [SessionState] = history.map(\.state)
        // The snapshot stream keeps only the newest unconsumed value, so early states may collapse.
        let sawStart = states.contains(.preparing) || states.contains(.connecting) || states.contains(.running)
        #expect(sawStart)
        #expect(states.last == .completed)
    }

    @Test("Engine closing the session on its own winds the session down with a visible reason", .timeLimit(.minutes(1)))
    func engineCloseAutoCompletes() async throws {
        let coordinator = SessionCoordinator(sessionID: "close")
        let anchor = MonotonicClock.nowNs()
        let script = FakeScript.lecture(sentences: [FakeSentence("Thank you.", "谢谢。")], startMs: 30, translationDelayMs: 40, wordIntervalMs: 20, pauseBetweenMs: 40)
        let factories = LaneFactories(
            makeCapture: { cfg in ToneCapture(laneID: cfg.id, sessionAnchorNs: anchor) },
            makeProvider: { _ in FakeProvider(script: script) }
        )
        let lane = LaneConfiguration(id: "remote", source: .system, sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "fake.demo")
        await coordinator.start(lanes: [lane], factories: factories)
        let deadline = MonotonicClock.nowNs() + 4_000_000_000
        var snap = await coordinator.currentSnapshot
        while MonotonicClock.nowNs() < deadline, snap.state != .completed {
            try await Task.sleep(nanoseconds: 50_000_000)
            snap = await coordinator.currentSnapshot
        }
        #expect(snap.state == .completed)
        #expect(snap.detail?.contains("引擎已结束会话") == true)
        #expect(snap.lanes.first?.capture.state == .stopped)
        #expect(snap.captions.segments.first?.translation?.text == "谢谢。")
    }

    @Test("Scripted disconnect bumps provider epoch; stale event from the old epoch is dropped", .timeLimit(.minutes(1)))
    func reconnectEpoch() async throws {
        let coordinator = SessionCoordinator(sessionID: "epoch")
        let anchor = MonotonicClock.nowNs()
        let provider = FakeProvider(script: .edgeCases)
        provider.speed = 4
        let factories = LaneFactories(
            makeCapture: { cfg in ToneCapture(laneID: cfg.id, sessionAnchorNs: anchor) },
            makeProvider: { _ in provider }
        )
        let lane = LaneConfiguration(id: "remote", source: .system, sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "fake.demo")
        await coordinator.start(lanes: [lane], factories: factories)
        let deadline = MonotonicClock.nowNs() + 5_000_000_000
        var snap = await coordinator.currentSnapshot
        while MonotonicClock.nowNs() < deadline {
            snap = await coordinator.currentSnapshot
            if snap.captions.segments.contains(where: { $0.translation?.text == "有问题吗？" }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(snap.lanes.first?.providerEpoch == 2)
        #expect(snap.captions.activeProviderEpochs["remote"] == 2)
        #expect(!snap.captions.segments.contains { $0.sourceText.contains("SHOULD NOT APPEAR") })
        #expect(snap.captions.segments.filter { $0.sourceText == "Thank you." }.count == 2)
        #expect(snap.captions.segments.first { $0.providerSegmentID == "s3" }?.translation?.text == "我们会失去复盘的证据。")
        await coordinator.stop()
    }
}
