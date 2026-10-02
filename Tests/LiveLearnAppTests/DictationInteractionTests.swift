import AppKit
import SwiftUI
import Testing
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct DictationInteractionTests {
    @Test(arguments: [false, true]) func captionCloseReceivesRealWindowMouseEvents(locked: Bool) async throws {
        let suite = "LiveLearn.testing.overlayClick.\(UUID())"
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: prefs)
        var snapshot = SampleData.runningSnapshot(includeGap: false)
        snapshot.captions = CaptionSnapshot(sessionID: snapshot.sessionID)
        let model = AppModel(settings: settings, preview: snapshot)
        model.overlayLocked = locked
        let overlay = OverlayPanelController(model: model)
        overlay.install()
        let panel = try #require(overlay.verificationWindow)
        defer { panel.orderOut(nil) }
        overlay.revealForVerification()
        try await Task.sleep(for: .milliseconds(250))
        #expect(panel.isVisible)
        let point = CGPoint(x: panel.frame.width - 24, y: panel.frame.height - 22)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            panel.sendEvent(event)
        }
        for _ in 0..<75 where panel.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.overlayVisible)
        #expect(!panel.isVisible)
        #expect(!(panel.contentView is OverlayHostingView))
    }

    @Test func hostingViewConvertsToolbarClicksOnlyOnce() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let hosting = OverlayHostingView(rootView: AnyView(Color.clear.frame(width: 600, height: 180)))
        let layout = OverlayLayout(); layout.width = 600; layout.controlsVisible = true
        hosting.layout = layout; panel.contentView = hosting
        #expect(layout.routesToControls(hosting.controlPoint(fromWindow: CGPoint(x: 575, y: 160))))
        #expect(!layout.routesToControls(hosting.controlPoint(fromWindow: CGPoint(x: 300, y: 30))))
    }

    @Test func waveformTracksEnergyAndDoesNotInventSilenceMotion() {
        var meter = DictationMeter()
        let silence = meter.heights
        for _ in 0..<30 { meter.consume(rms: 0) }
        #expect(meter.heights == silence && silence == [4, 4, 4, 4, 4])
        meter.consume(rms: 0.1)
        let attack = meter.level
        #expect(attack > 0)
        #expect(meter.heights[2] > meter.heights[0] && meter.heights[2] > meter.heights[4])
        meter.consume(rms: 0)
        #expect(abs(meter.level - attack * 0.85) < 0.0001)
        for _ in 0..<100 { meter.consume(rms: 0) }
        #expect(meter.level == 0 && meter.heights == silence)
        meter.consume(rms: .nan)
        #expect(meter.level == 0)
    }

    @Test func pillUsesCaretScreenAndStaysInsideSmallDisplays() {
        let screen = CGRect(x: -1280, y: 100, width: 1280, height: 800)
        let target = CGRect(x: -50, y: 110, width: 2, height: 20)
        let size = DictationPanelLayout.size(text: String(repeating: "中文 SwiftUI ", count: 50), notice: nil)
        #expect(size.height == 56 && size.width <= 736)
        let frame = DictationPanelLayout.frame(size: size, near: target, screen: screen)
        #expect(screen.contains(frame))
        #expect(frame.minY >= target.maxY)
        let bottom = DictationPanelLayout.frame(size: .init(width: 260, height: 56), near: nil, screen: screen)
        #expect(bottom.midX == screen.midX && bottom.minY == screen.minY + 28)
    }

    @Test func clipboardRestoresAllTypesAndDoesNotOverwriteNewUserCopy() {
        let pb = NSPasteboard(name: .init("LiveLearn.testing.\(UUID())"))
        defer { pb.releaseGlobally() }
        let rich = NSPasteboardItem()
        rich.setString("original", forType: .string)
        rich.setData(Data([1, 2, 3]), forType: .rtf)
        pb.writeObjects([rich])
        let snapshot = DictationPasteboardSnapshot(pb)
        pb.clearContents(); pb.setString("dictation", forType: .string)
        snapshot.restore(pb, ifUnchanged: pb.changeCount)
        #expect(pb.string(forType: .string) == "original")
        #expect(pb.data(forType: .rtf) == Data([1, 2, 3]))
        let change = pb.changeCount
        pb.clearContents(); pb.setString("user copied something new", forType: .string)
        snapshot.restore(pb, ifUnchanged: change)
        #expect(pb.string(forType: .string) == "user copied something new")
    }

    @Test func newPreferencesUseChineseAndPersistFnChoice() {
        let suite = "LiveLearn.testing.\(UUID())"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let s = DictationSettings(defaults: store)
        #expect(s.language == "zh-CN")
        #expect(!s.holdWithFn)
        s.holdWithFn = true; s.language = "ja-JP"
        let restored = DictationSettings(defaults: store)
        #expect(restored.holdWithFn && restored.language == "ja-JP")
    }
}
