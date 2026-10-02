import Foundation
import Testing
@testable import LiveLearnApp

@MainActor
struct SettingsModeTests {
    @Test func modePersistsWithoutResettingEngineConfiguration() {
        let suite = "LiveLearn.testing.settings-mode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.settingsMode == .standard)
        settings.settingsMode = .developer
        settings.realtimeBaseURL = "wss://example.test/realtime"
        settings.realtimeLegacyProtocol = true
        settings.cloudPartialTranslation = true
        settings.requestedSettingsTab = .diagnostics
        #expect(AppSettings(defaults: defaults).settingsMode == .developer)
        settings.settingsMode = .standard
        #expect(settings.requestedSettingsTab == .privacy)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.settingsMode == .standard)
        #expect(restored.realtimeBaseURL == "wss://example.test/realtime")
        #expect(restored.realtimeLegacyProtocol && restored.cloudPartialTranslation)
    }

    @Test func ordinaryModeRetainsConfigurationAndRecoveryDestinations() {
        let ordinary = LiveLearnSettingsPage.pages(in: .standard)
        #expect(ordinary.contains(.engine) && ordinary.contains(.localModels))
        #expect(ordinary.contains(.sources) && ordinary.contains(.language))
        #expect(ordinary.contains(.dictation) && ordinary.contains(.textTranslation) && ordinary.contains(.browserExtension))
        #expect(!ordinary.contains(.diagnostics))
        #expect(Set(LiveLearnSettingsPage.pages(in: .developer)) == Set(LiveLearnSettingsPage.allCases))
        #expect(!LiveLearnSettingsPage.allCases.contains { $0.group == "实时字幕" })
        #expect(LiveLearnSettingsPage.sources.group == nil)
    }

    @Test func selectionRailMatchesBothModeLayoutsAfterSwitching() {
        let motion = SettingsRailMotion()
        for mode in SettingsMode.allCases {
            for page in LiveLearnSettingsPage.pages(in: mode) {
                let index = LiveLearnSettingsPage.allCases.firstIndex(of: page)!
                let points = motion.sample(time: 2, selection: index, stationary: true, mode: mode)
                let center = LiveLearnSettingsPage.railCenterY(page, mode: mode)
                #expect(points.allSatisfy { abs($0.y - center) <= 16.01 })
                #expect(center > 0 && center < LiveLearnSettingsPage.listHeight(in: mode))
            }
        }
    }
}
