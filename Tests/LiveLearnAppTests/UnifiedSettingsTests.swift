import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct UnifiedSettingsTests {
    @Test func translationNavigationUsesTheSameModalAndPreservesItsSection() {
        let suite = "LiveLearn.testing.translation-settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let presentation = UnifiedSettingsPresentation()
        var requests = 0
        presentation.configure(settings: settings) { requests += 1 }
        presentation.showTranslation(section: 6)
        #expect(presentation.isPresented)
        #expect(settings.requestedSettingsTab == .textTranslation)
        #expect(presentation.translationSection == 6)
        #expect(requests == 1)
        let requestID = presentation.translationSectionRequestID
        presentation.dismiss()
        #expect(!presentation.isPresented)
        #expect(settings.requestedSettingsTab == .textTranslation)
        presentation.open()
        #expect(presentation.translationSection == 6)
        #expect(presentation.translationSectionRequestID == requestID)
        presentation.showTranslation(section: 6)
        #expect(presentation.translationSectionRequestID != requestID)
    }

    @Test func everySharedNavigationDestinationReturnsToItsOriginalSettingsPage() {
        for page in LiveLearnSettingsPage.allCases {
            #expect(page.settingsTab.navigationPage == page)
        }
        #expect(SettingsTab(rawValue: 8) == .shortcuts)
        #expect(SettingsTab(rawValue: 10) == .browserExtension)
        #expect(SettingsTab.vocabulary.navigationPage == nil)
        #expect(Set(LiveLearnSettingsPage.allCases.compactMap(\.shortcut).map(\.character)).count == 10)
    }

    @Test func settingsNavigationPreservesTheWindowAndOriginalTranslationSection() throws {
        var framer = TranslationReplyFramer(token: "settings-test")
        let frame = "LIVELEARN_TRANSLATION:settings-test:{\"ok\":true,\"event\":\"settingsNavigation\",\"settingsPage\":\"textTranslation\",\"settingsSection\":1,\"settingsFrame\":[100,160,1080,740]}\n"
        let replies = try framer.append(Data(frame.utf8))
        #expect(replies.count == 1)
        #expect(replies[0].settingsSection == 1)
        #expect(replies[0].settingsPage == "textTranslation")
    }
}
