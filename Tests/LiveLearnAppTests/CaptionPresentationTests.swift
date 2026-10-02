import AppKit
import SwiftUI
import Testing
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct CaptionPresentationTests {
    @Test func modeAndWidthsPersistIndependentlyWithoutErasingLayeredPreferences() {
        let suite = "LiveLearn.testing.caption-presentation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.captionPresentation == .layered && settings.captionDisplayWidth == 880)
        settings.showSourceInOverlay = true
        settings.showPreviousLine = true
        settings.showBreathLine = true
        settings.captionDisplayWidth = 960
        settings.captionPresentation = .singleLine
        #expect(settings.captionDisplayWidth == 640)
        settings.captionDisplayWidth = 560
        let restored = AppSettings(defaults: defaults)
        #expect(restored.captionPresentation == .singleLine && restored.captionDisplayWidth == 560)
        restored.captionPresentation = .layered
        #expect(restored.captionDisplayWidth == 960)
        #expect(restored.showSourceInOverlay && restored.showPreviousLine && restored.showBreathLine)
    }

    @Test func pendingTranslationKeepsTheLastTranslationWithoutShowingASourceRow() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        let pending = try #require(segments.last)
        let previous = try #require(segments.dropLast().last)
        #expect(SingleLineCaptionContent(current: pending, previous: nil) == nil)
        let held = try #require(SingleLineCaptionContent(current: pending, previous: previous))
        #expect(held.text == previous.translation?.text && held.isStale)
        #expect(!held.text.contains(pending.sourceText))
    }

    @Test func longTranslationsBecomeCompleteCuesThatFitOneLine() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        let full = String(repeating: "这是连续更新的长字幕，", count: 60) + "\n最新内容"
        segment.translation?.text = full
        let content = try #require(SingleLineCaptionContent(current: segment, previous: nil))
        let font = NSFont.systemFont(ofSize: 26, weight: .medium)
        let cues = content.cues(width: 400, font: font)
        #expect(cues.count > 1 && cues.last?.hasSuffix("最新内容") == true)
        #expect(cues.allSatisfy { !$0.contains("\n") && ($0 as NSString).size(withAttributes: [.font: font]).width <= 400 })
        #expect(cues.joined().filter { !$0.isWhitespace } == full.filter { !$0.isWhitespace })
        #expect(content.text == full && segment.translation?.text == full)
    }

    @Test func englishWordsStayTogetherAndUnbrokenWordsStillFit() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.translation?.text = "Keep the current subtitle still, then replace it with the next sentence. WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
        let content = try #require(SingleLineCaptionContent(current: segment, previous: nil))
        let font = NSFont.systemFont(ofSize: 26)
        let cues = content.cues(width: 440, font: font)
        #expect(cues.first == "Keep the current subtitle still,")
        #expect(cues.allSatisfy { ($0 as NSString).size(withAttributes: [.font: font]).width <= 440 })
        #expect(cues.joined().filter { !$0.isWhitespace } == content.text.filter { !$0.isWhitespace })
    }

    @Test func singleLineStaysOneRowEvenWithAllLayeredOptionsEnabled() throws {
        let suite = "LiveLearn.testing.caption-height.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showPreviousLine = true
        settings.showSourceInOverlay = true
        settings.showBreathLine = true
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        let style = OverlayStyle.resolve(settings, forceOpaque: false)
        func height() -> CGFloat {
            NSHostingView(rootView: LaneBlock(lane: nil, current: segments.last, previous: segments.dropLast().last,
                                             settings: settings, style: style, statusText: "已暂停")
                .frame(width: 592).environment(\.staticRender, true)).fittingSize.height
        }
        let layered = height()
        settings.captionPresentation = .singleLine
        let compact = height()
        #expect(compact == SingleLineCaptionView.lineHeight(fontSize: 26))
        #expect(compact < layered / 3)
    }

    @Test func twoAudioLanesChooseOneLatestTranslatedLane() throws {
        let suite = "LiveLearn.testing.caption-lanes.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: SampleData.runningSnapshot(dual: true))
        var tails = model.laneTails
        tails["mic"]?.current?.endNs = 90_000_000_000
        let selected = try #require(SingleLineCaptionContent.lane(from: model.lanes, tails: tails))
        #expect(selected.id == "mic")
        tails["mic"]?.current?.translation = nil
        tails["mic"]?.previous?.translation = nil
        #expect(SingleLineCaptionContent.lane(from: model.lanes, tails: tails)?.id == "remote")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_RENDER_CAPTION_MODES"] != nil))
    func renderBothPresentations() throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_RENDER_CAPTION_MODES"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.caption-render.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showPreviousLine = true
        settings.showSourceInOverlay = true
        let model = AppModel(settings: settings, preview: SampleData.runningSnapshot(includeGap: false))
        for mode in CaptionPresentation.allCases {
            settings.captionPresentation = mode
            let view = ThemedRoot(forced: .stellar) {
                OverlayView(forcedWidth: settings.captionDisplayWidth).environment(model)
                    .background(Color(hex: 0x0D0E10))
            }.environment(\.staticRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let cg = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(mode.rawValue).png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_VERIFY_CAPTION_CUES"] != nil))
    func singleLineHoldsStillThenReplacesTheWholeCue() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_VERIFY_CAPTION_CUES"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.caption-motion.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.captionPresentation = .singleLine
        settings.overlayContrastMode = .manual
        settings.overlayTextHex = "FFFFFF"
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.translation?.text = "字幕固定在画面底部，一句一句地切换。长句会自动分段，始终只占一行，让画面成为主角。"
        let style = OverlayStyle.resolve(settings, forceOpaque: false)
        let view = LaneBlock(lane: nil, current: segment, previous: nil, settings: settings, style: style, statusText: "")
            .padding(.horizontal, 24).frame(width: 640, height: 70)
        let panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 640, height: 70),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = NSColor(white: 0.08, alpha: 1)
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let frame = panel.frame
        let first = output.appendingPathComponent("cue-start.png")
        let held = output.appendingPathComponent("cue-held.png")
        let later = output.appendingPathComponent("cue-next.png")
        try #require(WindowCapture.write(panel, to: first))
        try await Task.sleep(for: .milliseconds(700))
        try #require(WindowCapture.write(panel, to: held))
        #expect(try Data(contentsOf: first) == Data(contentsOf: held))
        try await Task.sleep(for: .milliseconds(2200))
        try #require(WindowCapture.write(panel, to: later))
        #expect(panel.frame == frame)
        #expect(try Data(contentsOf: first) != Data(contentsOf: later))
    }
}
