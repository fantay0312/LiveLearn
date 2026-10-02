import AppKit
import Testing
import AudioDomain
import CaptionDomain
import EngineKit
import ProviderAdapters
import CloudEngine
@testable import LiveLearnApp

private final class DictationTestCapture: AudioCapture, @unchecked Sendable {
    let laneID = "dictation"
    let events: AsyncStream<CaptureEvent>
    let continuation: AsyncStream<CaptureEvent>.Continuation
    private let lock = NSLock()
    private var running = false
    var isRunning: Bool { lock.withLock { running } }
    init() { (events, continuation) = AsyncStream.makeStream() }
    func prepare(_ source: AudioSourceDescriptor) async throws { }
    func start() async throws { lock.withLock { running = true } }
    func stop() async { lock.withLock { running = false }; continuation.yield(.stopped(epoch: 1)) }
}

private final class DictationTestRecognizer: SpeechRecognizer, @unchecked Sendable {
    let descriptor = EngineStageDescriptor(id: "test", displayName: "Test", modelID: "test", isLocal: true, dataDestination: "", costUnit: "")
    let events: AsyncStream<RecognizerEvent>
    let continuation: AsyncStream<RecognizerEvent>.Continuation
    var startDelay = Duration.zero
    var finalText = "用 SwiftUI 调用 API。"
    init() { (events, continuation) = AsyncStream.makeStream() }
    func availability(sourceLanguage: String?) async -> StageAvailability { .ready }
    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        if startDelay > .zero { try await Task.sleep(for: startDelay) }
        return .init(inputFormat: .init(sampleRate: 16000, channelCount: 1), events: events)
    }
    func push(_ packet: ProviderAudioPacket) async { }
    func finalizePending() async { }
    func finish() async throws {
        continuation.yield(.chunk(.init(startNs: 0, endNs: 300, text: finalText, isFinal: true)))
        continuation.finish()
    }
    func cancel() async { continuation.finish() }
}

private struct DictationRefinementFixture: HTTPTransport {
    var delay: Duration = .milliseconds(900)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: delay)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"text\":\"用 SwiftUI 调用 API。\"}"]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor private final class DictationTestTarget: DictationTextTarget {
    let appName = "Fixture"
    var writes: [String] = []
    var changed = false
    var hostFocused = false
    var restored = false
    func replace(with text: String) throws {
        if hostFocused { throw DictationInputError.hostFocused }
        if changed { throw DictationInputError.changed }
        writes.append(text)
    }
    func restoreOriginalSelection() throws {
        if changed { throw DictationInputError.changed }
        restored = true
    }
    func commit(_ text: String) async throws {
        hostFocused = false
        try replace(with: text)
    }
}

@MainActor private final class DelayedDictationPaste: DictationTextTarget {
    let appName = "Delayed fixture"
    let supportsLiveInsertion = false
    var started = false
    var finished = false
    func replace(with text: String) throws { Issue.record("fallback must not receive partial writes") }
    func restoreOriginalSelection() throws { }
    func commit(_ text: String) async throws {
        started = true
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
        }
        finished = true
        throw DictationInputError.unconfirmed
    }
}

@MainActor private final class DictationPasteTarget: DictationTextTarget {
    let appName = "Paste fixture"
    let supportsLiveInsertion = false
    var commits: [String] = []
    var changed = false
    var canConfirmDelivery = true
    func replace(with text: String) throws { Issue.record("paste-only editor received a partial write") }
    func restoreOriginalSelection() throws { Issue.record("paste-only editor has no partial text to restore") }
    func commit(_ text: String) async throws {
        if changed { throw DictationInputError.changed }
        commits.append(text)
    }
}

@MainActor
struct DictationControllerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_VISUAL_DIR"] != nil))
    func renderAutomaticDeliverySuccess() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_VISUAL_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (controller, _, _, _) = harness()
        let target = DictationPasteTarget()
        controller.targetFactory = { target }
        controller.install(); controller.start()
        defer { controller.shutdown() }
        try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .completed }
        try await Task.sleep(for: .milliseconds(250))
        #expect(WindowCapture.write(controller.verificationWindow, to: directory.appendingPathComponent("delivered.png")))
        try await Task.sleep(for: .milliseconds(850))
        #expect(controller.verificationWindow?.isVisible == false)
        #expect(controller.verificationWindow?.contentView == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_VISUAL_DIR"] != nil))
    func renderActualCapsuleAndMeterStates() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_VISUAL_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (controller, engine, mic, _) = harness()
        controller.configuration = {
            let config = OpenAICompatibleConfig(vendorID: "fixture", displayName: "Fixture", baseURL: URL(string: "http://localhost")!, model: "fixture", apiKey: nil, isLocal: true, destination: "本机")
            return DictationConfiguration(recognizer: engine, language: "zh-CN", vocabulary: ["SwiftUI", "API"], replacements: [],
                corrector: DictationCorrector(config: config, transport: DictationRefinementFixture()), microphoneID: nil, liveInsertion: false)
        }
        controller.install(); controller.start(previewOnly: true)
        defer { controller.shutdown() }
        try await until { controller.phase == .listening }
        try await Task.sleep(for: .milliseconds(450))
        #expect(WindowCapture.write(controller.verificationWindow, to: directory.appendingPathComponent("capsule-listening.png")))
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "用 SwiftUI 调用 API，保留中英文的原始表达。", isFinal: false)))
        for index in 1...12 {
            let samples = (0..<1600).map { Float(sin(Double($0) * 0.1)) * 0.12 }
            mic.continuation.yield(.packet(AudioPacket(laneID: "dictation", captureEpoch: 1, sequence: UInt64(index),
                sourceStartNs: Int64(index - 1) * 100_000_000, sourceEndNs: Int64(index) * 100_000_000,
                format: .init(sampleRate: 16000, channelCount: 1), samples: OwnedAudioBuffer(channels: [samples]), discontinuityBefore: false)))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(WindowCapture.write(controller.verificationWindow, to: directory.appendingPathComponent("capsule-speaking.png")))
        controller.finish()
        try await until { controller.phase == .correcting }
        try await Task.sleep(for: .milliseconds(300))
        #expect(WindowCapture.write(controller.verificationWindow, to: directory.appendingPathComponent("capsule-correcting.png")))
        try await until { controller.phase == .completed }
        controller.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.verificationWindow?.isVisible == false)
        #expect(controller.verificationWindow?.contentView == nil)
    }

    private func harness() -> (DictationController, DictationTestRecognizer, DictationTestCapture, DictationTestTarget) {
        let defaults = UserDefaults(suiteName: "LiveLearn.testing.dictation.\(UUID())")!
        let controller = DictationController(settings: DictationSettings(defaults: defaults))
        let recognizer = DictationTestRecognizer(), capture = DictationTestCapture(), target = DictationTestTarget()
        controller.captureFactory = { capture }
        controller.targetFactory = { target }
        controller.configuration = {
            DictationConfiguration(recognizer: recognizer, language: nil, vocabulary: ["SwiftUI", "API"], replacements: [],
                                   corrector: nil, microphoneID: nil, liveInsertion: true)
        }
        return (controller, recognizer, capture, target)
    }

    private func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "state change did not arrive within one second")
    }

    @Test func streamsCorrectionsThenDrainsFinalBeforeCompleting() async throws {
        let (controller, engine, mic, target) = harness()
        controller.start()
        try await until { controller.phase == .listening }
        #expect(mic.isRunning)
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "用 swift ui", isFinal: false)))
        try await until { target.writes.last == "用 SwiftUI" }
        controller.finish()
        try await until { controller.phase == .completed }
        #expect(!mic.isRunning)
        #expect(target.writes.last == "用 SwiftUI 调用 API。")
        #expect(controller.text == "用 SwiftUI 调用 API。")
    }

    @Test func changedTargetStopsEveryFurtherWriteButKeepsFinalPreview() async throws {
        let (controller, engine, _, target) = harness()
        controller.start(); try await until { controller.phase == .listening }
        target.changed = true
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "中文", isFinal: false)))
        try await until { controller.notice != nil }
        target.changed = false
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.writes.isEmpty)
        #expect(controller.text == "用 SwiftUI 调用 API。")
    }

    @Test func cancellingStartupDoesNotStartMicrophoneOrInsertLateResults() async throws {
        let (controller, engine, mic, target) = harness()
        engine.startDelay = .milliseconds(100)
        controller.start()
        try await Task.sleep(for: .milliseconds(20))
        controller.cancel(); controller.cancel()
        try await until { !controller.isActive }
        try await Task.sleep(for: .milliseconds(150))
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "旧结果", isFinal: true)))
        #expect(!mic.isRunning)
        #expect(target.writes.isEmpty)
        #expect(controller.phase == .idle)
    }

    @Test func releaseWhileRecognizerLoadsStopsCaptureAndThenFinalizes() async throws {
        let (controller, engine, mic, target) = harness()
        engine.startDelay = .milliseconds(150)
        controller.beginHolding(source: "custom")
        try await until { mic.isRunning }
        controller.endHolding(source: "fn")
        #expect(mic.isRunning)
        controller.endHolding(source: "custom")
        try await until { !mic.isRunning }
        try await until { controller.phase == .completed }
        #expect(target.writes.last == "用 SwiftUI 调用 API。")
    }

    @Test func cancelledPasteFinishesItsLeaseBeforeAnotherSessionCanStart() async throws {
        let (controller, _, _, _) = harness()
        let oldTarget = DelayedDictationPaste()
        controller.targetFactory = { oldTarget }
        controller.start(); try await until { controller.phase == .listening }
        controller.finish(); try await until { oldTarget.started }
        let priorNotice = controller.notice
        controller.cancel()
        controller.start()
        #expect(controller.cleaningUp && controller.phase == .idle)
        try await until { !controller.cleaningUp }
        #expect(oldTarget.finished)
        #expect(controller.notice == priorNotice)
        let nextEngine = DictationTestRecognizer(), nextTarget = DictationTestTarget()
        controller.targetFactory = { nextTarget }
        controller.captureFactory = { DictationTestCapture() }
        controller.configuration = {
            DictationConfiguration(recognizer: nextEngine, language: "zh-CN", vocabulary: [], replacements: [],
                corrector: nil, microphoneID: nil, liveInsertion: true)
        }
        controller.start(); try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .completed }
        #expect(nextTarget.writes.last == "用 SwiftUI 调用 API。")
        #expect(controller.notice == nil)
    }

    @Test func previewOnlyNeverCapturesExternalInput() async throws {
        let (controller, _, _, target) = harness()
        controller.targetFactory = { Issue.record("preview captured an external target"); return target }
        controller.start(previewOnly: true)
        try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.writes.isEmpty)
    }

    @Test func releasingHoldAutomaticallyPastesFinalTextOnce() async throws {
        let (controller, engine, mic, _) = harness()
        let target = DictationPasteTarget()
        controller.targetFactory = { target }
        controller.beginHolding(source: "custom")
        try await until { controller.phase == .listening }
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "用 swift ui", isFinal: false)))
        try await until { !controller.text.isEmpty }
        #expect(target.commits.isEmpty)
        controller.endHolding(source: "custom")
        controller.finish()
        try await until { controller.phase == .completed }
        #expect(!mic.isRunning)
        #expect(target.commits == ["用 SwiftUI 调用 API。"])
        #expect(controller.delivered)
        #expect(controller.notice == nil)
    }

    @Test func unavailableTargetDoesNotSilentlyBecomePreview() {
        let (controller, _, mic, _) = harness()
        controller.targetFactory = { throw DictationInputError.unsupported }
        controller.start()
        #expect(controller.phase == .failed)
        #expect(!mic.isRunning && !controller.delivered)
        #expect(controller.notice == DictationInputError.unsupported.description)
    }

    @Test func interfaceStartWaitsForInputThenDeliversToCapturedTarget() async throws {
        let (controller, _, mic, _) = harness()
        let target = DictationPasteTarget()
        var ready = false, captures = 0
        controller.targetFactory = {
            captures += 1
            guard ready else { throw DictationInputError.unsupported }
            return target
        }
        controller.selectInputAndStart()
        try await until { captures > 0 }
        #expect(controller.phase == .selectingInput && !mic.isRunning)
        ready = true
        try await until { controller.phase == .listening }
        let captured = captures
        controller.finish()
        try await until { controller.phase == .completed }
        #expect(captures == captured)
        #expect(target.commits == ["用 SwiftUI 调用 API。"])
        #expect(controller.delivered)
    }

    @Test func cancelledInputSelectionCannotStartRecordingLater() async throws {
        let (controller, _, mic, _) = harness()
        controller.selectInputAndStart()
        controller.cancel()
        try await Task.sleep(for: .milliseconds(160))
        #expect(!mic.isRunning)
        #expect(controller.phase == .idle)
    }

    @Test func changedPasteTargetKeepsResultWithoutSendingItElsewhere() async throws {
        let (controller, _, _, _) = harness()
        let target = DictationPasteTarget()
        controller.targetFactory = { target }
        controller.start(); try await until { controller.phase == .listening }
        target.changed = true
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.commits.isEmpty && !controller.delivered)
        #expect(controller.text == "用 SwiftUI 调用 API。")
        #expect(controller.notice == DictationInputError.changed.description)
    }

    @Test func emptyRecognitionNeverPastesOrReportsDelivery() async throws {
        let (controller, engine, _, _) = harness()
        let target = DictationPasteTarget()
        controller.targetFactory = { target }
        engine.finalText = ""
        controller.start(); try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.commits.isEmpty && !controller.delivered)
    }

    @Test func unobservablePasteKeepsRecoveryWithoutRetrying() async throws {
        let (controller, _, _, _) = harness()
        let target = DictationPasteTarget()
        target.canConfirmDelivery = false
        controller.targetFactory = { target }
        controller.start(); try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.commits == ["用 SwiftUI 调用 API。"])
        #expect(controller.delivered && !controller.deliveryConfirmed)
        #expect(controller.notice == "已发送粘贴，请确认输入框中的文字。")
    }

    @Test func openingOurMenuDoesNotDiscardOriginalInputTarget() async throws {
        let (controller, engine, _, target) = harness()
        controller.start(); try await until { controller.phase == .listening }
        target.hostFocused = true
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "菜单暂时取得焦点", isFinal: false)))
        try await until { !controller.text.isEmpty }
        #expect(target.writes.isEmpty)
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.writes.last == "用 SwiftUI 调用 API。")
        #expect(controller.delivered && controller.notice == nil)
    }

    @Test func finalCorrectionIsPastedOnlyAfterRefinementCompletes() async throws {
        let (controller, engine, _, _) = harness()
        let target = DictationPasteTarget()
        engine.finalText = "用 SwiftUI 调用 API"
        controller.targetFactory = { target }
        controller.configuration = {
            let config = OpenAICompatibleConfig(vendorID: "fixture", displayName: "Fixture", baseURL: URL(string: "http://localhost")!, model: "fixture", apiKey: nil, isLocal: true, destination: "本机")
            return DictationConfiguration(recognizer: engine, language: "zh-CN", vocabulary: ["SwiftUI", "API"], replacements: [],
                corrector: DictationCorrector(config: config, transport: DictationRefinementFixture(delay: .milliseconds(100))), microphoneID: nil, liveInsertion: false)
        }
        controller.start(); try await until { controller.phase == .listening }
        controller.finish(); try await until { controller.phase == .correcting }
        #expect(target.commits.isEmpty)
        try await until { controller.phase == .completed }
        #expect(target.commits == ["用 SwiftUI 调用 API。"])
        #expect(controller.delivered)
    }

    @Test func emptyFinalRestoresOnlyOurUntouchedSelection() async throws {
        let (controller, engine, _, target) = harness()
        engine.finalText = ""
        controller.start(); try await until { controller.phase == .listening }
        engine.continuation.yield(.chunk(.init(startNs: 0, endNs: 100, text: "错误猜测", isFinal: false)))
        try await until { !target.writes.isEmpty }
        controller.finish(); try await until { controller.phase == .completed }
        #expect(target.restored)
        #expect(controller.text.isEmpty)
    }

    @Test func panelNeverBecomesKeyOrMain() {
        let (controller, _, _, _) = harness()
        let hud = DictationPanelController(controller: controller)
        #expect(!hud.panel.canBecomeKey && !hud.panel.canBecomeMain)
        #expect(hud.panel.styleMask.contains(.nonactivatingPanel))
        #expect(!hud.panel.isVisible)
    }

    @Test func preferencesDoNotChangeCaptionEngineOrInstallShortcuts() {
        let suite = "LiveLearn.testing.dictation.\(UUID())"
        // Use an isolated persistent domain; these preferences must survive reconstruction.
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: isolated)
        let captionEngine = settings.recognizer
        settings.dictation.engine = RecognizerChoice.doubao.rawValue
        settings.dictation.replacements = "扣德克斯=Codex"
        let restored = AppSettings(defaults: isolated)
        #expect(restored.dictation.engine == RecognizerChoice.doubao.rawValue)
        #expect(restored.dictation.rules.first?.target == "Codex")
        #expect(restored.recognizer == captionEngine)
        #expect(restored.hotKeyBindings.isEmpty)
        #expect(!restored.dictation.finalCorrection)
    }
}
