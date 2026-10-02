import Foundation
import Testing
import MacAudio
import SessionStorage
@testable import LiveLearnApp

@MainActor
struct SessionSourceSelectionTests {
    @Test func refreshingDraftChoicesDoesNotSelectAMicrophoneOrChangeSources() {
        let suite = "LiveLearn.testing.inventory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(settings: AppSettings(defaults: defaults), store: SessionStore(directory: folder), credentials: .empty)
        model.select(microphone: nil)
        let original = SessionSourceSelection(model: model)
        model.refreshSourceInventory()
        #expect(model.selectedMicrophone == nil)
        #expect(SessionSourceSelection(model: model) == original)
        #expect(model.settings.lastMicUID == nil)
    }

    @Test func draftApplicationMenuNeverMutatesLiveSourcesOrWidensAnEmptySelection() {
        let suite = "LiveLearn.testing.source-menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot())
        let original = SessionSourceSelection(model: model)
        var draft = original
        draft.computer = .system
        let app = RunningApplicationSummary(bundleIdentifier: "test.app", name: "Test", path: nil, pid: 0, isPlayingAudio: false)
        draft.toggleApplication(app)
        #expect(draft.computer == .applications && draft.applications.map(\.bundleIdentifier) == ["test.app"])
        draft.toggleApplication(app)
        #expect(draft.computer == .applications && draft.applications.isEmpty)
        #expect(draft.validationError == "请选择要收听的应用。")
        #expect(SessionSourceSelection(model: model) == original)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"] != nil))
    func realSourceEditorRestartKeepsRecordAndCurrentPage() async throws {
        let audio = try #require(ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"])
        let suite = "LiveLearn.testing.live-source-edit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(settings: AppSettings(defaults: defaults), store: SessionStore(directory: folder), credentials: .empty)
        model.captureFileOverride = URL(fileURLWithPath: audio)
        let ready = await model.blueprint.readiness(source: "en", target: "zh-Hans")
        let reverse = await model.blueprint.readiness(source: "zh-Hans", target: "en")
        try #require(ready.isReady && reverse.isReady)
        model.start()
        defer { model.stop() }
        let deadline = Date().addingTimeInterval(18)
        while (model.captions.segments.isEmpty || model.sessionState != .running) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(model.isActive && !model.captions.segments.isEmpty)
        let oldID = model.sessionID
        let oldSource = model.lanes.first?.configuration.source
        model.requestRecords()
        var selection = SessionSourceSelection(model: model)
        selection.languages.listenSource = "zh-Hans"
        selection.languages.listenTarget = "en"
        let error = await model.applySessionSources(selection)
        try #require(error == nil, "\(error ?? "")")
        let restarted = Date().addingTimeInterval(12)
        while (model.sessionID == oldID || model.lanes.isEmpty || model.sessionState != .running) && Date() < restarted {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.isRunning && model.sessionID != oldID)
        #expect(model.mainPage == .transcript)
        #expect(model.records.contains { $0.id == oldID && !$0.archive.segments.isEmpty })
        #expect(model.lanes.first?.configuration.source == oldSource)
        #expect(model.lanes.first?.configuration.sourceLanguage == "zh-Hans")
        #expect(model.lanes.first?.configuration.targetLanguage == "en")
        model.stop()
        let stopped = Date().addingTimeInterval(12)
        while model.isActive && Date() < stopped { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.isActive)
    }

    @Test func cancelledSourceDraftDoesNotChangeTheRunningSession() {
        let suite = "LiveLearn.testing.source-draft.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot())
        let initial = SessionSourceSelection(model: model)
        var draft = initial
        draft.computer = .off
        draft.microphoneEnabled = true
        draft.languages.micSource = "ja"
        draft.languages.micTarget = "en"
        #expect(SessionSourceSelection(model: model) == initial)
        #expect(model.isActive)
    }

    @Test func invalidSourcesAndLanguagesLeaveCurrentSessionUntouched() async {
        let suite = "LiveLearn.testing.invalid-source.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot())
        let initial = SessionSourceSelection(model: model)
        let snapshot = model.snapshot
        var draft = initial
        draft.computer = .off
        draft.microphoneEnabled = false
        #expect(await model.applySessionSources(draft) == "请至少启用一个音源。")
        draft.computer = .applications
        draft.applications = []
        #expect(await model.applySessionSources(draft) == "请选择要收听的应用。")
        draft.computer = .system
        draft.languages.listenTarget = draft.languages.listenSource
        #expect(await model.applySessionSources(draft) == "识别语言和输出语言需要不同。")
        #expect(SessionSourceSelection(model: model) == initial)
        #expect(model.snapshot == snapshot && model.isActive)
    }

    @Test func unavailableEngineRejectsSourceChangesBeforePersistingThem() async {
        let suite = "LiveLearn.testing.source-readiness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        settings.translator = .anthropic
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        let initial = SessionSourceSelection(model: model)
        var draft = initial
        draft.computer = .applications
        draft.applications = [RunningApplicationSummary(bundleIdentifier: "test.app", name: "Test", path: nil, pid: 0, isPlayingAudio: false)]
        #expect(await model.applySessionSources(draft) != nil)
        #expect(SessionSourceSelection(model: model) == initial)
        #expect(!settings.listenToApplications && !model.isReconfiguringSession)
    }
}
