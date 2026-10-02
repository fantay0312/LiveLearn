import Foundation
import Testing
import SessionStorage
import WhisperEngine
@testable import LiveLearnApp

@MainActor
struct OverlayEngineTests {
    @Test func missingWhisperModelDoesNotReplaceConfiguration() async {
        let suite = "LiveLearn.testing.engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        let before = model.blueprint
        let id = model.sessionID
        let error = await model.applyOverlayEngines(recognizer: .whisperKit, whisperModel: "LiveLearn-uninstalled-model", translator: .appleTranslation)
        #expect(error?.contains("尚未下载") == true)
        #expect(model.blueprint == before && model.sessionID == id)
        #expect(settings.recognizer == .appleSpeech && settings.whisperModel == before.whisper.variant)
        #expect(!model.isReconfiguringSession)
    }

    @Test func changingOnlyWhisperModelRefreshesBlueprint() async throws {
        let suite = "LiveLearn.testing.engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        settings.recognizer = .whisperKit
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        settings.whisperModel = "openai_whisper-base"
        let deadline = Date().addingTimeInterval(2)
        while model.blueprint.whisper.variant != settings.whisperModel && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.blueprint.whisper.variant == "openai_whisper-base")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_WHISPER_SWITCH_AUDIO"] != nil))
    func realAppleToWhisperSwitchKeepsTranscriptAndRecognizesSpeech() async throws {
        let audio = try #require(ProcessInfo.processInfo.environment["LIVELEARN_WHISPER_SWITCH_AUDIO"])
        let endpoint = try #require(ProcessInfo.processInfo.environment["LIVELEARN_MOCK_TRANSLATOR_URL"])
        let variant = "openai_whisper-base"
        try #require(WhisperModelStore.isInstalled(variant))
        let suite = "LiveLearn.testing.whisperswitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        settings.translator = .chat
        settings.chatVendor = .custom
        settings.setChatBaseURL(endpoint, for: .custom)
        settings.setChatModel("overlay-test", for: .custom)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        model.captureFileOverride = URL(fileURLWithPath: audio)
        let ready = await model.blueprint.readiness(source: "en", target: "zh-Hans")
        try #require(ready.isReady, "\(ready.blocker ?? "")")
        model.start()
        defer { model.stop() }
        let firstDeadline = Date().addingTimeInterval(25)
        while model.captions.segments.isEmpty && Date() < firstDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(model.isActive && !model.captions.segments.isEmpty)
        let oldID = model.sessionID
        model.overlayLocked = true
        let missing = await model.applyOverlayEngines(recognizer: .whisperKit, whisperModel: "LiveLearn-uninstalled-model", translator: .chat)
        #expect(missing?.contains("尚未下载") == true)
        #expect(model.sessionID == oldID && model.isActive && settings.recognizer == .appleSpeech)
        let error = await model.applyOverlayEngines(recognizer: .whisperKit, whisperModel: variant, translator: .chat)
        try #require(error == nil, "\(error ?? "")")
        let deadline = Date().addingTimeInterval(55)
        while (model.sessionID == oldID || !model.captions.segments.contains(where: { $0.translation != nil })) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.sessionID != oldID && model.overlayLocked)
        #expect(model.records.contains { $0.id == oldID && $0.archive.segmentCount > 0 })
        #expect(model.blueprint.recognizer == .whisperKit && model.blueprint.whisper.variant == variant)
        #expect(model.lanes.first?.configuration.sourceLanguage == "en")
        #expect(model.lanes.first?.configuration.targetLanguage == "zh-Hans")
        #expect(model.captions.segments.contains { $0.translation != nil },
                "state=\(model.sessionState) failure=\(model.snapshot.failure ?? "none") captions=\(model.captions.segments.map(\.sourceText))")
        print("Whisper switch evidence: archived=\(model.records.count), source=\(model.captions.segments.map(\.sourceText))")
        model.stop()
        let stopDeadline = Date().addingTimeInterval(12)
        while model.isActive && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.isActive)
    }
}
