import Foundation
import AppKit
import Testing
import SessionStorage
@testable import LiveLearnApp

@MainActor
struct OverlaySettingsTests {
    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) rethrows {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }

    @Test func transparentBackgroundPersistsWithoutFadingText() {
        withSettings { settings, defaults in
            settings.overlayOpacity = 0.65
            settings.overlayOpacity = 0
            settings.captionTargetSize = 34
            let restored = AppSettings(defaults: defaults)
            let transparent = OverlayStyle.resolve(restored, forceOpaque: false)
            restored.overlayOpacity = 1
            let solid = OverlayStyle.resolve(restored, forceOpaque: false)
            #expect(transparent.opacity == 0 && solid.opacity == 1)
            #expect(transparent.text == solid.text)
            #expect(restored.captionTargetSize == 34)
        }
    }

    @Test func accessibilityAndInvalidOpacityRemainBounded() {
        withSettings { settings, _ in
            settings.overlayOpacity = -0.5
            #expect(OverlayStyle.resolve(settings, forceOpaque: false).opacity == 0)
            settings.overlayOpacity = 8
            #expect(OverlayStyle.resolve(settings, forceOpaque: false).opacity == 1)
            settings.overlayOpacity = .nan
            #expect(OverlayStyle.resolve(settings, forceOpaque: false).opacity == 0)
            settings.overlayOpacity = 0
            #expect(OverlayStyle.resolve(settings, forceOpaque: true).opacity == 1)
            #expect(OverlayStyle.resolve(settings, forceOpaque: false, increasedContrast: true).opacity == 1)
        }
    }

    @Test func restoredCustomStyleIsKeptUntilExplicitReset() {
        withSettings { settings, defaults in
            settings.overlayOpacity = 0.84
            settings.showPreviousLine = true
            settings.showBreathLine = true
            let restored = AppSettings(defaults: defaults)
            #expect(restored.overlayOpacity == 0.84 && restored.showPreviousLine)
            restored.resetOverlayStyle()
            #expect(restored.overlayOpacity == 0 && !restored.overlayOpaque)
            #expect(!restored.showBreathLine && !restored.showPreviousLine)
        }
    }

    @Test func toolbarReceivesClicksButCaptionBodyStillDrags() {
        let layout = OverlayLayout()
        layout.width = 480
        #expect(!layout.routesToControls(CGPoint(x: 20, y: 20)))
        layout.controlsVisible = true
        #expect(layout.routesToControls(CGPoint(x: 20, y: 20)))
        #expect(layout.routesToControls(CGPoint(x: 470, y: 32)))
        #expect(!layout.routesToControls(CGPoint(x: 250, y: 80)))
        #expect(!layout.routesToControls(CGPoint(x: -1, y: 20)))
        #expect(!layout.routesToControls(CGPoint(x: 481, y: 20)))
    }

    @Test func lockedBodyPassesThroughButTopEdgeRevealsUnlockControls() {
        let layout = OverlayLayout()
        layout.width = 480
        layout.isLocked = true
        let frame = CGRect(x: 100, y: 100, width: 480, height: 200)
        layout.updatePointer(CGPoint(x: 200, y: 150), in: frame, visible: true)
        #expect(layout.ignoresMouseEvents(fadingOut: false))
        #expect(!layout.controlsVisible)
        layout.updatePointer(CGPoint(x: 560, y: 285), in: frame, visible: true)
        #expect(layout.controlsVisible && layout.pointerOnToolbar)
        #expect(!layout.ignoresMouseEvents(fadingOut: false))
        #expect(layout.routesToControls(CGPoint(x: 460, y: 15)))
        layout.updatePointer(CGPoint(x: 200, y: 180), in: frame, visible: true)
        #expect(layout.ignoresMouseEvents(fadingOut: false))
        layout.updatePointer(CGPoint(x: 120, y: 285), in: frame, visible: true)
        #expect(!layout.ignoresMouseEvents(fadingOut: false))
        #expect(layout.ignoresMouseEvents(fadingOut: true))
        layout.isLocked = false
        layout.updatePointer(CGPoint(x: 200, y: 180), in: frame, visible: true)
        #expect(!layout.ignoresMouseEvents(fadingOut: false))
        layout.isLocked = true
        layout.updatePointer(CGPoint(x: 120, y: 285), in: frame, visible: false)
        #expect(!layout.pointerOnToolbar && layout.ignoresMouseEvents(fadingOut: false))
    }

    @Test func languageDraftCanBeCancelledWithoutChangingPreferences() {
        withSettings { settings, defaults in
            var draft = OverlayLanguages(settings: settings)
            draft.listenTarget = "ja"
            draft.micSource = "auto"
            #expect(AppSettings(defaults: defaults).listenTargetLanguage == "zh-Hans")
            draft.apply(to: settings)
            let restored = AppSettings(defaults: defaults)
            #expect(restored.listenTargetLanguage == "ja" && restored.micSourceLanguage == "auto")
            #expect(draft.directions(computer: true, microphone: false).count == 1)
            #expect(draft.directions(computer: true, microphone: true).count == 2)
        }
    }

    @Test func invalidLanguageDraftDoesNotStopSessionOrChangeSettings() async {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: SampleData.runningSnapshot())
        var draft = OverlayLanguages(settings: settings)
        draft.listenTarget = draft.listenSource
        let originalID = model.sessionID
        let error = await model.applyOverlayLanguages(draft)
        #expect(error == "识别语言和输出语言需要不同。")
        #expect(model.sessionID == originalID && model.isActive)
        #expect(settings.listenTargetLanguage == "zh-Hans")
    }

    @Test func overlaySystemSymbolsExist() {
        for symbol in ["waveform", "speaker.wave.2", "pause.circle", "play.circle", "cpu", "globe", "captions.bubble.fill", "captions.bubble", "textformat.size", "circle.lefthalf.filled", "lock.open", "lock.fill", "xmark"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func unavailableTranslatorDoesNotReplaceCurrentSettings() async {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        let original = model.blueprint
        let error = await model.applyOverlayTranslator(.anthropic)
        #expect(error != nil)
        #expect(settings.translator == .appleTranslation)
        #expect(model.blueprint == original)
        #expect(!model.isReconfiguringSession)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_MOCK_TRANSLATOR_URL"] != nil))
    func realTranslatorSwitchKeepsSourceAndPriorTranscript() async throws {
        let audio = try #require(ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"])
        let endpoint = try #require(ProcessInfo.processInfo.environment["LIVELEARN_MOCK_TRANSLATOR_URL"])
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        settings.chatVendor = .custom
        settings.setChatBaseURL(endpoint, for: .custom)
        settings.setChatModel("overlay-test", for: .custom)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        model.captureFileOverride = URL(fileURLWithPath: audio)
        let ready = await model.blueprint.readiness(source: "en", target: "zh-Hans")
        try #require(ready.isReady)
        model.start()
        defer { model.stop() }
        let initialDeadline = Date().addingTimeInterval(18)
        while model.captions.segments.isEmpty && Date() < initialDeadline { try await Task.sleep(for: .milliseconds(100)) }
        try #require(model.isActive && !model.captions.segments.isEmpty)
        let previousID = model.sessionID
        model.overlayLocked = true
        let error = await model.applyOverlayTranslator(.chat)
        try #require(error == nil, "\(error ?? "")")
        let deadline = Date().addingTimeInterval(18)
        while !model.captions.segments.contains(where: { $0.translation?.text.hasPrefix("译:") == true }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.sessionID != previousID)
        #expect(model.records.contains { $0.id == previousID && $0.archive.segmentCount > 0 })
        #expect(model.blueprint.recognizer == .appleSpeech && model.blueprint.translator == .chat)
        #expect(model.overlayLocked)
        #expect(model.lanes.first?.configuration.sourceLanguage == "en")
        #expect(model.lanes.first?.configuration.targetLanguage == "zh-Hans")
        #expect(model.captions.segments.contains { $0.translation?.text.hasPrefix("译:") == true },
                "state=\(model.sessionState) failure=\(model.snapshot.failure ?? "none") lanes=\(model.lanes.map { $0.lastError ?? $0.providerName }) captions=\(model.captions.segments.map { $0.translation?.text ?? $0.sourceText })")
        model.stop()
        let stopDeadline = Date().addingTimeInterval(12)
        while model.isActive && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.isActive)
    }

    /// Opt-in real-engine acceptance: supply a speech file and installed en/zh Apple models.
    /// Normal unit runs remain independent of local model downloads and capture permissions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"] != nil))
    func realLanguageRestartKeepsPriorTranscript() async throws {
        let audio = try #require(ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"])
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder))
        model.captureFileOverride = URL(fileURLWithPath: audio)
        let initial = await model.blueprint.readiness(source: "en", target: "zh-Hans")
        let reversed = await model.blueprint.readiness(source: "zh-Hans", target: "en")
        try #require(initial.isReady && reversed.isReady, "Install both Apple language directions before this live acceptance run.")
        model.start()
        defer { model.stop() }
        let firstDeadline = Date().addingTimeInterval(18)
        while (model.captions.segments.isEmpty || model.lanes.isEmpty) && Date() < firstDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(!model.captions.segments.isEmpty && model.isActive)
        let originalID = model.sessionID
        var selection = OverlayLanguages(settings: settings)
        selection.listenSource = "zh-Hans"
        selection.listenTarget = "en"
        let error = await model.applyOverlayLanguages(selection)
        try #require(error == nil, "\(error ?? "")")
        let restartDeadline = Date().addingTimeInterval(12)
        while (model.sessionID == originalID || model.lanes.isEmpty) && Date() < restartDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let newID = model.sessionID
        #expect(newID != originalID)
        #expect(model.records.contains { $0.id == originalID && $0.archive.segmentCount > 0 })
        #expect(model.lanes.first?.configuration.sourceLanguage == "zh-Hans")
        #expect(model.lanes.first?.configuration.targetLanguage == "en")
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.sessionID == newID, "The old stream must not overwrite the restarted session.")
        model.stop()
        let stopDeadline = Date().addingTimeInterval(12)
        while model.isActive && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.isActive)
    }
}
