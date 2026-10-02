import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct ExperienceThemeTests {
    @Test func detachedSceneStopsRendering() {
        _ = NSApplication.shared
        let view = ExplorationSCNView(frame: .zero, options: nil)
        view.configure(world: .stellar)
        view.motionEnabled = true
        view.updatePlayback()
        #expect(!view.isPlaying)
        #expect(!view.rendersContinuously)
        #expect(view.scene?.isPaused == true)
    }

    @Test func bothWorldsUseBoundedRealGeometry() {
        for world in ExperienceTheme.allCases {
            let model = ExplorationWorldModel(world: world, animated: false)
            #expect(model.triangleCount > 500)
            #expect(model.triangleCount < 250000)
            if world == .stellar { #expect(model.imageTextureCount >= 5) }
        }
    }

    @Test func themePersistsAndUnknownValuesFallBack() {
        let suite = "LiveLearn.testing.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.experienceTheme == .stellar)
        #expect(!settings.showBackgroundScene)
        settings.showBackgroundScene = true
        #expect(AppSettings(defaults: defaults).showBackgroundScene)
        settings.experienceTheme = .wilds
        #expect(AppSettings(defaults: defaults).experienceTheme == .wilds)
        settings.experienceTheme = .stellar
        #expect(AppSettings(defaults: defaults).experienceTheme == .stellar)
        defaults.set("future-unknown-world", forKey: "experienceTheme")
        #expect(AppSettings(defaults: defaults).experienceTheme == .stellar)
    }

    @Test func themeDoesNotChangeCaptionOrEnginePreferences() {
        let suite = "LiveLearn.testing.theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.overlayTextHex = "12AB34"
        settings.overlayBackgroundHex = "123456"
        settings.captionTargetSize = 33
        settings.overlayOpacity = 0.31
        settings.hotWords = ["LiveLearn"]
        let recognizer = settings.recognizer
        let translator = settings.translator
        settings.experienceTheme = .wilds
        let restored = AppSettings(defaults: defaults)
        #expect(restored.overlayTextHex == "12AB34")
        #expect(restored.overlayBackgroundHex == "123456")
        #expect(restored.captionTargetSize == 33)
        #expect(restored.overlayOpacity == 0.31)
        #expect(restored.hotWords == ["LiveLearn"])
        #expect(restored.recognizer == recognizer && restored.translator == translator)
        settings.resetOverlayStyle()
        #expect(settings.experienceTheme == .wilds)
    }
}
