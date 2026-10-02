import Testing
import Foundation
@testable import AudioDomain
@testable import CaptionDomain
@testable import ProviderAdapters
@testable import SessionDomain

/// Capture that emits nothing on its own; tests push packets by hand.
final class ManualCapture: AudioCapture, @unchecked Sendable {
    let laneID: String
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    init(laneID: String = "remote") {
        self.laneID = laneID
        let s = AsyncStream<CaptureEvent>.makeStream()
        events = s.stream
        continuation = s.continuation
    }
    func prepare(_ source: AudioSourceDescriptor) async throws {}
    func start() async throws {
        continuation.yield(.started(epoch: 1, format: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)))
    }
    func stop() async { continuation.yield(.stopped(epoch: 1)) }
    func packet(_ sequence: UInt64, amplitude: Float = 0.1) {
        let f = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        continuation.yield(.packet(AudioPacket(laneID: laneID, captureEpoch: 1, sequence: sequence, sourceStartNs: Int64(sequence - 1) * 100_000_000, sourceEndNs: Int64(sequence) * 100_000_000, format: f, samples: OwnedAudioBuffer(mono: Array(repeating: amplitude, count: 4800)), discontinuityBefore: false)))
    }
    func health(_ h: CaptureHealth) { continuation.yield(.health(h)) }
}

/// Provider whose failure shape the test chooses.
final class ScriptedFailureProvider: TranslationProvider, @unchecked Sendable {
    let capabilities = FakeProvider(script: .demoTalk).capabilities
    let events: AsyncStream<ProviderEvent>
    let continuation: AsyncStream<ProviderEvent>.Continuation
    private let lock = NSLock()
    private var opens = 0
    private var pushes = 0
    var pushError: ProviderError?
    var reopenError: ProviderError?
    var closeBeforeReturning = false
    init() {
        let s = AsyncStream<ProviderEvent>.makeStream()
        events = s.stream
        continuation = s.continuation
    }
    var openCount: Int { lock.withLock { opens } }
    var pushCount: Int { lock.withLock { pushes } }
    func open(_ c: ProviderSessionConfiguration) async throws {
        let n = lock.withLock { opens += 1; return opens }
        if n > 1, let e = reopenError { throw e }
        continuation.yield(.opened(providerEpoch: c.providerEpoch))
    }
    func push(_ p: ProviderAudioPacket) async throws {
        lock.withLock { pushes += 1 }
        if let e = pushError { throw e }
    }
    func finishInput() async throws {
        continuation.yield(.closed(providerEpoch: 1))
        if closeBeforeReturning { try await Task.sleep(for: .milliseconds(40)) }
    }
    func cancel() async {}
    func disconnect() { continuation.yield(.disconnected(providerEpoch: 1, error: ProviderError(.retryable, "link lost"))) }
}

private let lane = LaneConfiguration(id: "remote", source: .system, sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "test")

@Suite("Lane and session failure paths")
struct FailurePathTests {

    @Test("B12: a close that arrives before stop installs its wait is honored, no timeout")
    func earlyClose() async throws {
        let provider = ScriptedFailureProvider()
        provider.closeBeforeReturning = true
        let coordinator = LaneCoordinator(sessionID: "s", configuration: lane, capture: ManualCapture(), provider: provider, sessionAnchorNs: MonotonicClock.nowNs())
        try await coordinator.start()
        try await Task.sleep(for: .milliseconds(30))
        let t0 = MonotonicClock.nowNs()
        await coordinator.stop(drainTimeoutNs: 500_000_000)
        let took = MonotonicClock.nowNs() - t0
        let status = await coordinator.status
        #expect(status.lastError == nil)
        #expect(status.providerLink == .closed)
        #expect(took < 400_000_000, "stop waited for the timeout: \(took / 1_000_000) ms")
        // Idempotent: a second stop returns immediately and changes nothing.
        await coordinator.stop()
        #expect(await coordinator.status.providerLink == .closed)
    }

    @Test("B11: reconnect attempts stop at the configured limit and the lane fails")
    func reconnectLimit() async throws {
        let provider = ScriptedFailureProvider()
        provider.reopenError = ProviderError(.retryable, "refused")
        let coordinator = LaneCoordinator(sessionID: "s", configuration: lane, capture: ManualCapture(), provider: provider, sessionAnchorNs: MonotonicClock.nowNs())
        await coordinator.setLimit(1)
        try await coordinator.start()
        try await Task.sleep(for: .milliseconds(30))
        provider.disconnect()
        var status = await coordinator.status
        let deadline = MonotonicClock.nowNs() + 3_000_000_000
        while status.providerLink != .failed, MonotonicClock.nowNs() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = await coordinator.status
        }
        #expect(status.providerLink == .failed)
        #expect(provider.openCount == 2, "initial open + exactly one retry, got \(provider.openCount)")
        #expect(status.isUploading == false)
        await coordinator.stop(drainTimeoutNs: 100_000_000)
        #expect(provider.openCount == 2, "stop must not reconnect")
    }

    @Test("B10: a permanent upload error fails the lane, ends the session, and records the unsent audio as a gap")
    func permanentUploadError() async throws {
        let provider = ScriptedFailureProvider()
        provider.pushError = ProviderError(.permanent, "quota exhausted")
        let capture = ManualCapture()
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in capture }, makeProvider: { _ in provider }))
        try await Task.sleep(for: .milliseconds(30))
        capture.packet(1)
        capture.packet(2)
        var snap = await session.currentSnapshot
        let deadline = MonotonicClock.nowNs() + 2_000_000_000
        while snap.state != .completed, MonotonicClock.nowNs() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            snap = await session.currentSnapshot
        }
        #expect(snap.state == .completed)
        #expect(snap.lanes.first?.providerLink == .failed)
        #expect(snap.lanes.first?.isUploading == false)
        #expect(snap.failure?.contains("quota exhausted") == true)
        let gaps = snap.captions.items.compactMap { if case .gap(let g) = $0 { return g } else { return nil } }
        #expect(gaps.contains { $0.reason == GapReason.uploadFailed.rawValue }, "unsent audio must appear as a gap: \(gaps.map(\.reason))")
        #expect(provider.pushCount == 1, "after a permanent error no further packets are pushed")
    }

    @Test("B18: a capture reporting 'capturing' with silent callbacks is shown as waiting, and last-audio is kept")
    func silentCallbacksAreNotCapturing() async throws {
        let provider = ScriptedFailureProvider()
        let capture = ManualCapture()
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in capture }, makeProvider: { _ in provider }))
        try await Task.sleep(for: .milliseconds(30))
        capture.packet(1, amplitude: 0)
        capture.health(CaptureHealth(laneID: "remote", captureEpoch: 1, state: .capturing, callbackCount: 1))
        try await Task.sleep(for: .milliseconds(60))
        var snap = await session.currentSnapshot
        #expect(snap.lanes.first?.capture.state == .waitingForAudio)
        #expect(snap.lanes.first?.capture.lastAudioNs == nil)
        capture.packet(2, amplitude: 0.2)
        try await Task.sleep(for: .milliseconds(60))
        capture.health(CaptureHealth(laneID: "remote", captureEpoch: 1, state: .capturing, callbackCount: 2))
        try await Task.sleep(for: .milliseconds(60))
        snap = await session.currentSnapshot
        #expect(snap.lanes.first?.capture.state == .capturing)
        #expect(snap.lanes.first?.capture.lastAudioNs == 200_000_000, "structural health must not erase the last audio time")
        await session.stop()
    }

    @Test("B04: the demo script holds while paused and an engine that closes while paused ends the session")
    func pausedScriptAndClose() async throws {
        let script = FakeScript.lecture(sentences: [FakeSentence("First.", "一。"), FakeSentence("Second.", "二。")], startMs: 150, translationDelayMs: 20, wordIntervalMs: 20, pauseBetweenMs: 60)
        let provider = FakeProvider(script: script)
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in ManualCapture() }, makeProvider: { _ in provider }))
        await session.pause()
        try await Task.sleep(for: .milliseconds(600))
        var snap = await session.currentSnapshot
        #expect(snap.state == .paused)
        #expect(snap.captions.segments.isEmpty, "paused script produced \(snap.captions.segments.count) segments")
        await session.resume()
        let deadline = MonotonicClock.nowNs() + 4_000_000_000
        while snap.state != .completed, MonotonicClock.nowNs() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            snap = await session.currentSnapshot
        }
        #expect(snap.captions.segments.count == 2, "after resume the script continues")
        #expect(snap.state == .completed)

        // Engine closes while paused: the session must not stay "已暂停".
        let provider2 = ScriptedFailureProvider()
        let session2 = SessionCoordinator(sessionID: "s2")
        await session2.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in ManualCapture() }, makeProvider: { _ in provider2 }))
        try await Task.sleep(for: .milliseconds(30))
        await session2.pause()
        provider2.continuation.yield(.closed(providerEpoch: 1))
        var snap2 = await session2.currentSnapshot
        let deadline2 = MonotonicClock.nowNs() + 2_000_000_000
        while snap2.state == .paused, MonotonicClock.nowNs() < deadline2 {
            try await Task.sleep(for: .milliseconds(30))
            snap2 = await session2.currentSnapshot
        }
        #expect(snap2.state == .completed, "state \(snap2.state)")
        #expect(snap2.detail?.contains("引擎已结束会话") == true)
    }

    @Test("B05: stopping with an open partial freezes it and marks it incomplete")
    func unfinishedAtStop() async throws {
        let script = FakeScript(name: "u", sourceLanguage: "en", targetLanguage: "zh-Hans", steps: [
            .source(atMs: 0, segment: "s1", revision: 1, text: "Done.", startMs: 0, endMs: 40, isFinal: true, eventID: nil),
            .translation(atMs: 10, translationID: "t1", refs: [SourceRef(segmentID: "s1", revision: 1)], text: "完成。", isFinal: true, eventID: nil),
            .source(atMs: 20, segment: "s2", revision: 1, text: "Please do not", startMs: 50, endMs: 90, isFinal: false, eventID: nil),
        ])
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in ManualCapture() }, makeProvider: { _ in FakeProvider(script: script) }))
        try await Task.sleep(for: .milliseconds(120))
        await session.stop()
        let snap = await session.currentSnapshot
        let segs = snap.captions.segments
        #expect(segs.count == 2)
        #expect(segs.first?.presentationState == .final)
        #expect(segs.first?.isIncomplete == false)
        #expect(segs.last?.presentationState == .frozen)
        #expect(segs.last?.isIncomplete == true)
        #expect(segs.last?.sourceText == "Please do not")
    }

    @Test("B15: elapsed time stops at completion")
    func elapsedFrozen() async throws {
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in ManualCapture() }, makeProvider: { _ in ScriptedFailureProvider() }))
        try await Task.sleep(for: .milliseconds(50))
        await session.stop()
        let a = await session.currentSnapshot.elapsedNs
        try await Task.sleep(for: .milliseconds(80))
        let b = await session.currentSnapshot.elapsedNs
        #expect(a == b)
        #expect(a >= 50_000_000)
    }

    @Test("B03: the demo provider refuses a language pair it has no script for")
    func unsupportedPair() async {
        let provider = FakeProvider(script: .demoTalk)
        await #expect(throws: ProviderError.self) {
            try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "ja", targetLanguage: "ko", sourceKind: .system))
        }
        #expect(FakeScript.demo(source: "ja", target: "zh-Hans", gateOnVoice: false) == nil)
        #expect(FakeScript.demo(source: "en", target: "zh-Hans", gateOnVoice: true)?.steps.contains { if case .waitForVoice = $0 { return true } else { return false } } == true)
        #expect(FakeScript.demo(source: "zh-Hans", target: "en", gateOnVoice: false)?.steps.contains { if case .waitForVoice = $0 { return true } else { return false } } == false)
    }

    @Test("B09/T04: a target that quit leaves the session degraded and waiting, not finished")
    func sourceUnavailableKeepsSession() async throws {
        let capture = ManualCapture()
        let session = SessionCoordinator(sessionID: "s")
        await session.start(lanes: [lane], factories: LaneFactories(makeCapture: { _ in capture }, makeProvider: { _ in ScriptedFailureProvider() }))
        try await Task.sleep(for: .milliseconds(30))
        capture.health(CaptureHealth(laneID: "remote", captureEpoch: 1, state: .sourceUnavailable, detail: "Safari 已退出；重新打开后会自动继续"))
        try await Task.sleep(for: .milliseconds(80))
        var snap = await session.currentSnapshot
        #expect(snap.state == .degraded)
        capture.health(CaptureHealth(laneID: "remote", captureEpoch: 2, state: .waitingForAudio, detail: "已连接"))
        try await Task.sleep(for: .milliseconds(80))
        snap = await session.currentSnapshot
        #expect(snap.state == .running)
        await session.stop()
    }
}

extension LaneCoordinator {
    func setLimit(_ n: Int) { maxReconnectAttempts = n }
}
