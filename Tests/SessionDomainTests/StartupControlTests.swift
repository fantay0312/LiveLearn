import Foundation
import Testing
import AudioDomain
import CaptionDomain
import ProviderAdapters
@testable import SessionDomain

private actor StartupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reached = false
    private var released = false
    func wait() async {
        reached = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private final class StartupCapture: AudioCapture, @unchecked Sendable {
    let laneID = "remote"
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    let prepareGate: StartupGate?
    let startGate: StartupGate?
    private let lock = NSLock()
    private var active = false
    private var starts = 0
    var running: Bool { lock.withLock { active } }
    var startCount: Int { lock.withLock { starts } }
    init(prepareGate: StartupGate? = nil, startGate: StartupGate? = nil) {
        self.prepareGate = prepareGate; self.startGate = startGate
        let stream = AsyncStream<CaptureEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
    }
    func prepare(_ source: AudioSourceDescriptor) async throws { await prepareGate?.wait() }
    func start() async throws {
        await startGate?.wait()
        lock.withLock { active = true; starts += 1 }
        continuation.yield(.started(epoch: 1, format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)))
    }
    func stop() async { lock.withLock { active = false }; continuation.yield(.stopped(epoch: 1)) }
    func packet(_ sequence: UInt64) {
        continuation.yield(.packet(AudioPacket(laneID: laneID, captureEpoch: 1, sequence: sequence,
            sourceStartNs: Int64(sequence - 1) * 100_000_000, sourceEndNs: Int64(sequence) * 100_000_000,
            format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
            samples: OwnedAudioBuffer(mono: Array(repeating: 0.1, count: 1600)), discontinuityBefore: false)))
    }
}

private final class StartupProvider: TranslationProvider, @unchecked Sendable {
    let capabilities = FakeProvider(script: .demoTalk).capabilities
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    let gate: StartupGate?
    private let lock = NSLock()
    private var pushes = 0
    var pushCount: Int { lock.withLock { pushes } }
    init(gate: StartupGate? = nil) {
        self.gate = gate
        let stream = AsyncStream<ProviderEvent>.makeStream()
        events = stream.stream; continuation = stream.continuation
    }
    func open(_ configuration: ProviderSessionConfiguration) async throws {
        await gate?.wait()
        continuation.yield(.opened(providerEpoch: configuration.providerEpoch))
    }
    func push(_ packet: ProviderAudioPacket) async throws { lock.withLock { pushes += 1 } }
    func finishInput() async throws { continuation.yield(.closed(providerEpoch: 1)) }
    func cancel() async {}
}

struct StartupControlTests {
    enum Checkpoint: CaseIterable, Sendable { case prepare, provider, capture }
    private var configuration: LaneConfiguration {
        LaneConfiguration(id: "remote", source: .system, sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "test")
    }

    @Test(arguments: Checkpoint.allCases)
    func stopDuringStartupCannotRestartCapture(_ checkpoint: Checkpoint) async throws {
        let gate = StartupGate()
        let capture = StartupCapture(prepareGate: checkpoint == .prepare ? gate : nil, startGate: checkpoint == .capture ? gate : nil)
        let provider = StartupProvider(gate: checkpoint == .provider ? gate : nil)
        let session = SessionCoordinator()
        let configuration = configuration
        let starting = Task { await session.start(lanes: [configuration], factories: LaneFactories(makeCapture: { _ in capture }, makeProvider: { _ in provider })) }
        defer { Task { await gate.release() } }
        let deadline = Date().addingTimeInterval(2)
        while !(await gate.reached) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await gate.reached)
        let before = Date()
        await session.stop()
        #expect(Date().timeIntervalSince(before) < 0.5)
        await gate.release()
        await starting.value
        let snapshot = await session.currentSnapshot
        #expect(snapshot.state == .completed)
        #expect(snapshot.lanes.allSatisfy { !$0.isUploading })
        #expect(!capture.running)
        if checkpoint != .capture { #expect(capture.startCount == 0) }
    }

    @Test func pauseDuringConnectionSurvivesStartupAndOnlyExplicitResumeForwardsAudio() async throws {
        let gate = StartupGate()
        let capture = StartupCapture()
        let provider = StartupProvider(gate: gate)
        let session = SessionCoordinator()
        let configuration = configuration
        let starting = Task { await session.start(lanes: [configuration], factories: LaneFactories(makeCapture: { _ in capture }, makeProvider: { _ in provider })) }
        defer { Task { await gate.release(); await session.stop() } }
        let deadline = Date().addingTimeInterval(2)
        while !(await gate.reached) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await gate.reached)
        await session.pause()
        await gate.release()
        await starting.value
        #expect(await session.currentSnapshot.state == .paused)
        capture.packet(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.pushCount == 0)
        await session.resume()
        capture.packet(2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.pushCount > 0)
        #expect(await session.currentSnapshot.state == .running)
        await session.stop()
    }
}
