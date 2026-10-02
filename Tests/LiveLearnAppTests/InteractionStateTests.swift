import AppKit
import Carbon.HIToolbox
import SwiftUI
import SessionStorage
import AudioDomain
import Testing
@testable import LiveLearnApp

@MainActor
struct InteractionStateTests {
    @Test func reducedWaveDoesNotTravelWhenAudioAdvancesItsPhase() throws {
        func pixels(phase: Float, reduced: Bool) throws -> Data {
            let trace = WaveTrace(samples: Array(repeating: 0.6, count: 64), phase: phase)
            let view = WaveLine(trace: trace, color: .white, echo: .gray, motion: .listening, height: 28, previewReducedMotion: reduced)
                .frame(width: 220, height: 28).background(.black)
                .environment(\.staticRender, true)
            let image = try #require(ImageRenderer(content: view).cgImage)
            return try #require(image.dataProvider?.data) as Data
        }
        #expect(try pixels(phase: 0.2, reduced: true) == pixels(phase: 2.8, reduced: true))
        #expect(try pixels(phase: 0.2, reduced: false) != pixels(phase: 2.8, reduced: false))
    }
    @Test func savedHistoryDoesNotClaimToBeUnsaved() throws {
        let suite = "LiveLearn.testing.saved-status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = SessionStore(directory: directory)
        let archive = SessionArchive(snapshot: SampleData.runningSnapshot(), title: "UI review", startedAt: Date(),
                                     outcome: .completed, appVersion: "test")
        try store.save(archive)
        let model = AppModel(settings: AppSettings(defaults: defaults), store: store, credentials: .empty)
        let record = try #require(model.records.first)
        model.showRecord(record)
        #expect(model.statusText == "已结束 · 已保存")
    }
    @Test func editingAPresetImmediatelyMakesItCustom() {
        let suite = "LiveLearn.testing.interaction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for preset in OverlayAppearancePreset.allCases where preset.isAvailable {
            preset.apply(to: settings)
            #expect(preset.matches(settings))
            settings.captionTargetSize += 1
            #expect(!preset.matches(settings))
            preset.apply(to: settings)
            settings.overlayOpaque = true
            #expect(!preset.matches(settings))
        }
    }

    @Test func settingsNavigationCannotBeStolenByGlobalShortcuts() {
        for key in [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                    kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9] {
            #expect(KeyCombo(keyCode: key, flags: [.command]).ownChordTitle()?.contains("设置页面切换") == true)
        }
    }

    @Test func reducedMotionRemovesControlTiming() {
        #expect(LLMotion.press(true, down: true) == nil)
        #expect(LLMotion.press(true, down: false) == nil)
        #expect(LLMotion.press(false, down: true) != nil)
    }
}
