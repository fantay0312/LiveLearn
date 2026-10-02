import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct InterfaceAdaptationTests {
    @Test func ultrawideScalesByUsableHeightRatherThanAspectRatio() {
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let wide = CGRect(x: 0, y: 0, width: 3440, height: 1407)
        let ultrawide = CGRect(x: -5120, y: 0, width: 5120, height: 1407)
        #expect(InterfaceLayout.scale(for: laptop, preference: .automatic) == 1)
        #expect(InterfaceLayout.scale(for: wide, preference: .automatic) == 1.5)
        #expect(InterfaceLayout.scale(for: ultrawide, preference: .automatic) == 1.5)
        #expect(InterfaceLayout.scale(for: CGRect(x: 0, y: 0, width: 7680, height: 4290), preference: .automatic) == 1.5)
    }

    @Test func smallScreensKeepTheMinimumLogicalCanvasVisible() {
        for size in [CGSize(width: 1024, height: 735), CGSize(width: 1280, height: 687), CGSize(width: 1512, height: 949)] {
            let screen = CGRect(origin: .zero, size: size)
            let scale = InterfaceLayout.scale(for: screen, preference: .largest)
            let frame = InterfaceLayout.windowFrame(current: CGRect(x: 900, y: 100, width: 1800, height: 1300), screen: screen, scale: scale, automatic: true)
            #expect(screen.contains(frame))
            #expect(frame.width / scale >= 960 - 0.001)
            #expect(frame.height / scale >= 600 - 0.001)
        }
    }

    @Test func movingBetweenScreensPreservesManualSizeAndClampsPosition() {
        let screen = CGRect(x: -3440, y: 250, width: 3440, height: 1407)
        let current = CGRect(x: -1400, y: 300, width: 1550, height: 1000)
        let manual = InterfaceLayout.windowFrame(current: current, screen: screen, scale: 1.5, automatic: false)
        #expect(manual.size == current.size)
        #expect(screen.contains(manual))
        #expect(InterfaceLayout.windowFrame(current: manual, screen: screen, scale: 1.5, automatic: false) == manual)
        let automatic = InterfaceLayout.windowFrame(current: current, screen: screen, scale: 1.5, automatic: true)
        #expect(automatic.size == CGSize(width: 1770, height: 1140))
        #expect(screen.contains(automatic))
    }

    @Test func manualInterfaceSizeSurvivesRelaunchWithoutChangingCaptionSize() {
        let suite = "LiveLearn.testing.interface.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let caption = settings.captionTargetSize
        #expect(settings.interfaceSize == .automatic)
        settings.interfaceSize = .large
        let restored = AppSettings(defaults: defaults)
        #expect(restored.interfaceSize == .large)
        #expect(restored.captionTargetSize == caption)
    }

    @Test func returningToLargeScreenRestoresTheUsersDesiredSize() {
        let large = CGRect(x: -3440, y: 0, width: 3440, height: 1407)
        let small = CGRect(x: 0, y: 0, width: 1512, height: 949)
        var sizing = InterfaceWindowSizing(restoredSize: CGSize(width: 1180, height: 760))
        sizing.userResized(to: CGSize(width: 1800, height: 1100))
        let smallFrame = InterfaceLayout.windowFrame(current: CGRect(x: 0, y: 0, width: 1800, height: 1100), screen: small,
            scale: 1, automatic: sizing.automatic, preferredSize: sizing.preferredSize)
        let returned = InterfaceLayout.windowFrame(current: smallFrame, screen: large,
            scale: 1.5, automatic: sizing.automatic, preferredSize: sizing.preferredSize)
        #expect(smallFrame.size != sizing.preferredSize)
        #expect(returned.size == sizing.preferredSize)
    }

    @Test func restoredAutomaticWindowKeepsAdaptingAfterRelaunch() throws {
        let initial = InterfaceWindowSizing(restoredSize: CGSize(width: 1180, height: 760))
        let restored = try JSONDecoder().decode(InterfaceWindowSizing.self, from: JSONEncoder().encode(initial))
        let frame = InterfaceLayout.windowFrame(current: CGRect(x: 0, y: 0, width: 1770, height: 1140),
            screen: CGRect(x: 0, y: 0, width: 1512, height: 949), scale: 1,
            automatic: restored.automatic, preferredSize: restored.preferredSize)
        #expect(restored.automatic)
        #expect(frame.size == CGSize(width: 1180, height: 760))
    }
}
