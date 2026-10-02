import AppKit
import Testing
import SessionStorage
@testable import LiveLearnApp

@MainActor
struct MainWindowLayoutTests {
    @Test func liveSessionUpdatesStayOnHomeUntilRecordsAreExplicitlyOpened() {
        let suite = "LiveLearn.testing.home-live.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        var live = SampleData.runningSnapshot()
        model.receive(live)
        #expect(model.isActive && model.mainPage == .home)
        model.requestRecords()
        live.state = .paused
        model.receive(live)
        #expect(model.mainPage == .transcript)
        model.requestHome()
        #expect(model.mainPage == .home && model.sessionState == .paused)
        live.state = .completed
        model.receive(live)
        #expect(model.mainPage == .home && !model.records.isEmpty)
        if let record = model.records.first { model.showRecord(record) }
        #expect(model.mainPage == .transcript)
    }

    @Test func vocabularyUsesMainPageAndRepeatedHomeClicksRemainExplicit() {
        let suite = "LiveLearn.testing.main-nav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        model.requestVocabularyWindow()
        #expect(model.mainPage == .vocabulary)
        #expect(model.openMainWindowRequest == 0, "The existing main window is reused")
        model.requestHome()
        #expect(model.mainPage == .home && model.sessionState == .idle)
        #expect(model.openHomeRequest == 1)
        model.requestHome()
        #expect(model.openHomeRequest == 2, "Already-home clicks must still collapse history")
        model.mainWindowVisible = false
        model.requestVocabularyWindow()
        #expect(model.openMainWindowRequest == 1 && model.mainPage == .vocabulary)
    }

    @Test func returningFromVocabularyDoesNotStopAnActiveSession() {
        let suite = "LiveLearn.testing.active-nav.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot())
        let before = model.captions
        model.requestVocabularyWindow()
        model.requestHome()
        #expect(model.isActive && model.mainPage == .home)
        #expect(model.captions == before)
    }

    @Test func historyPanelLeavesRoomForReadingAndNavigation() {
        for width in [CGFloat(960), 1180, 1440, 1920] {
            let panel = MainWindowLayout.historyWidth(windowWidth: width)
            #expect((264...304).contains(panel))
            #expect(width - panel - 1 >= 695)
        }
        for symbol in ["house", "sidebar.left", "clock", "book.closed", "textformat.size", "gearshape"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
        }
    }

    @Test func recordSearchFindsSourceAndTranslationWithoutCaseSensitivity() {
        let archive = SessionArchive(snapshot: SampleData.runningSnapshot(), title: "Release review", startedAt: Date(),
                                     outcome: .completed, appVersion: "test")
        let record = SessionRecord(archive: archive, saved: false)
        #expect(SidebarView.matches(record, query: ""))
        #expect(SidebarView.matches(record, query: "RELEASE"))
        #expect(SidebarView.matches(record, query: "server 重启"))
        #expect(!SidebarView.matches(record, query: "absent-term"))
    }

    @Test func recordsDestinationLoadsLatestAndRestoresTheSelectedArchive() {
        let suite = "LiveLearn.testing.records-destination.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        model.requestRecords()
        #expect(model.mainPage == .transcript && model.sessionState == .idle)
        var finished = SampleData.runningSnapshot()
        finished.state = .completed
        model.receive(finished)
        model.clearCompleted()
        model.requestVocabularyWindow()
        model.requestRecords()
        #expect(model.mainPage == .transcript && model.currentRecord?.id == finished.sessionID)
        let captions = model.captions
        model.requestHome()
        model.requestRecords()
        model.requestRecords()
        #expect(model.mainPage == .transcript && model.captions == captions)
        #expect(model.viewingRecordID == finished.sessionID)
    }
}
