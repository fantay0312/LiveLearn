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
}
