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

    @Test func pendingTranslationKeepsTheLastTranslationWithItsOwnSource() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        var pending = try #require(segments.last)
        let previous = try #require(segments.dropLast().last)
        #expect(SingleLineCaptionContent(current: pending, previous: nil) == nil)
        let held = try #require(SingleLineCaptionContent(current: pending, previous: previous))
        #expect(held.id == previous.id && held.text == previous.translation?.text)
        #expect(held.source == previous.sourceText)
        // The sentence being spoken takes the line with its first translation, stale or not.
        var partial = try #require(previous.translation)
        partial.text = "在我们分成两组之前"
        partial.isStale = true
        pending.translation = partial
        let live = try #require(SingleLineCaptionContent(current: pending, previous: previous))
        #expect(live.id == pending.id && live.text == "在我们分成两组之前" && live.source == pending.sourceText)
    }

    @Test func theSourceRowWalksALongSentenceWithItsTranslationAndNeverWraps() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = "Before we touch anything in production, let's look at what the logs are actually saying, then decide together."
        segment.translation?.text = "在动生产环境之前，我们先看看日志。"
        let content = try #require(SingleLineCaptionContent(current: segment, previous: nil))
        let font = NSFont.systemFont(ofSize: 26, weight: .medium), sourceFont = NSFont.systemFont(ofSize: 17)
        // Hidden source: one step per translated cue, nothing under it.
        #expect(content.steps(width: 592, font: font, sourceFont: nil).map(\.source) == [""])
        let steps = content.steps(width: 592, font: font, sourceFont: sourceFont)
        #expect(steps.count > 1 && Set(steps.map(\.text)) == ["在动生产环境之前，我们先看看日志。"])
        #expect(steps.allSatisfy { ($0.source as NSString).size(withAttributes: [.font: sourceFont]).width <= 592 && $0.hold >= 1.6 })
        #expect(steps.map(\.source).joined(separator: " ") == segment.sourceText)
        // Same text on both rows (nothing to translate): the row is not repeated.
        segment.translation?.text = segment.sourceText
        let same = try #require(SingleLineCaptionContent(current: segment, previous: nil))
        #expect(same.steps(width: 592, font: font, sourceFont: sourceFont).allSatisfy { $0.source.isEmpty })
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

    @Test func singleLineIsOneTranslatedRowAndAtMostItsSourceRowUnderIt() throws {
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
        let bilingual = height()
        #expect(bilingual == SingleLineCaptionView.lineHeight(fontSize: 26) + 4 + SingleLineCaptionView.sourceLineHeight(fontSize: 17))
        #expect(bilingual == SingleLineCaptionView.height(settings) && bilingual < layered / 2)
        settings.showSourceInOverlay = false
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

    /// Review renders: both presentations with a sentence still being spoken, over a dark frame,
    /// a bright one and a busy one, plus the plate an unlocked caption shows under the pointer.
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
        var snapshot = SampleData.runningSnapshot(includeGap: false)
        if case .segment(var live) = try #require(snapshot.captions.items.last),
           var partial = snapshot.captions.segments.dropLast().last?.translation {
            partial.text = "在我们分成两组之前，还有什么问题"
            partial.isFinal = false
            partial.isStale = true
            live.translation = partial
            snapshot.captions.items[snapshot.captions.items.count - 1] = .segment(live)
        }
        let model = AppModel(settings: settings, preview: snapshot)
        let hovered = OverlayLayout()
        hovered.pointerInside = true
        let backdrops: [(String, AnyView)] = [
            ("dark", AnyView(Color(hex: 0x0D0E10))),
            ("bright", AnyView(Color(hex: 0xF7F7F5))),
            ("busy", AnyView(LinearGradient(stops: [.init(color: Color(hex: 0xF2E9D8), location: 0), .init(color: Color(hex: 0x3B6EA5), location: 0.35),
                                                    .init(color: Color(hex: 0xFFFFFF), location: 0.5), .init(color: Color(hex: 0x1B1B1F), location: 0.7),
                                                    .init(color: Color(hex: 0xE8C547), location: 1)], startPoint: .leading, endPoint: .trailing))),
        ]
        func write(_ view: some View, _ name: String) throws {
            let renderer = ImageRenderer(content: ThemedRoot(forced: .stellar) { view }.environment(\.staticRender, true))
            renderer.scale = 2
            let cg = try #require(renderer.cgImage)
            let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        for mode in CaptionPresentation.allCases {
            settings.captionPresentation = mode
            for (name, backdrop) in backdrops {
                try write(OverlayView(forcedWidth: settings.captionDisplayWidth).environment(model).background(backdrop),
                          "\(mode.rawValue)-\(name)")
            }
            try write(OverlayView(forcedWidth: settings.captionDisplayWidth).environment(model).environment(hovered)
                .background(backdrops[2].1), "\(mode.rawValue)-hover")
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
