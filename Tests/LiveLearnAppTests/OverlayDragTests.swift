import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct OverlayDragTests {
    @Test func liveHeightUpdatesDoNotFightTheDraggedWindow() async throws {
        _ = NSApplication.shared
        let suite = "LiveLearn.testing.overlay-drag.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: SampleData.runningSnapshot(includeGap: false))
        let controller = OverlayPanelController(model: model, defaults: defaults)
        controller.install()
        let panel = try #require(controller.verificationWindow)
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        // Unlocked, the block takes the press that moves it (the lock policy has its own test).
        #expect(!panel.ignoresMouseEvents)
        let original = panel.frame
        let changes = controller.geometryApplicationCount
        #expect(controller.positionSaveCount == 0)
        controller.beginDragForVerification()
        for step in 1...30 {
            panel.setFrameOrigin(CGPoint(x: original.minX + CGFloat(step), y: original.minY + 30))
            controller.reportHeightForVerification(150 + CGFloat(step))
            #expect(panel.frame.size == original.size)
        }
        #expect(controller.geometryApplicationCount == changes)
        #expect(controller.positionSaveCount == 0)
        controller.finishDragForVerification()
        #expect(controller.positionSaveCount == 1)
        #expect(panel.frame.height == 180)
        #expect(abs(panel.frame.minY - (original.minY + 30)) < 1)
        #expect(controller.geometryApplicationCount <= changes + 1)
        controller.reportHeightForVerification(190)
        #expect(controller.positionSaveCount == 1)
        #expect(panel.frame.minY == original.minY + 30)
    }

    /// Asks the window server which window a press would land on; no event is posted. A clear
    /// panel left at AppKit's default lets a press on a transparent pixel fall through to the
    /// window below, which is why the caption could only be dragged by its glyph strokes.
    /// On screen and dependent on what else floats there, so it runs on request.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_VERIFY_CAPTION_HIT"] != nil))
    func aPressOnTheClearBlockLandsOnTheCaptionUnlessLocked() async throws {
        _ = NSApplication.shared
        let suite = "LiveLearn.testing.overlay-hit.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.overlayOpacity = 0
        let model = AppModel(settings: settings, preview: SampleData.runningSnapshot(includeGap: false))
        let controller = OverlayPanelController(model: model, defaults: defaults)
        controller.install()
        let panel = try #require(controller.verificationWindow)
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(panel.isVisible)
        // The panel's bottom-left corner: no glyph, no fill.
        let clear = CGPoint(x: panel.frame.minX + 6, y: panel.frame.minY + 6)
        func landsOnCaption() -> Bool {
            NSWindow.windowNumber(at: clear, belowWindowWithWindowNumber: 0) == panel.windowNumber
        }
        #expect(landsOnCaption())
        model.overlayLocked = true
        controller.sync()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!landsOnCaption())
        model.overlayLocked = false
        controller.sync()
        try await Task.sleep(for: .milliseconds(100))
        #expect(landsOnCaption())
    }
}
