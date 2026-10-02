import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LiveLearnApp

/// Round 12, settings host pages: the centred column, the paper star shared with the helper,
/// the rail's cut-edge fade and the section help mark. How the pages look is reviewed from the
/// renders (`--render-living-controls`, `--render-settings-modes`, `--render-previews`, and the
/// opt-in `gallery` here for the pages no fixture covers).
@MainActor
struct Round12SettingsTests {
    /// Every card `modalRect` can produce: the 576 pt column never reaches into the ✕'s corner
    /// column, never sits closer than 24 pt to the rail, and is centred in the pane wherever the
    /// ✕ leaves room for it (from a 672 pt pane, i.e. an 848 pt card, up).
    @Test func theColumnIsCentredInThePaneAndClearsTheClose() {
        let sidebar = LiveLearnSettingsPage.sidebarWidth
        let measure = LiveLearnSettingsPage.contentMeasure
        let close = LiveLearnSettingsPage.closeColumn
        for width in 825...1080 {
            let card = CGFloat(width)
            let pane = card - sidebar
            let gutter = LiveLearnSettingsPage.contentGutter(pane: pane)
            #expect(gutter >= 24)
            #expect(sidebar + gutter + measure <= card - close, "\(width)")
            if pane - measure >= 2 * close {
                #expect(abs((pane - gutter - measure) - gutter) < 0.001, "\(width) is not centred")
            }
        }
        // The two cards the fixtures render and the minimum one.
        #expect(LiveLearnSettingsPage.contentGutter(pane: 1080 - sidebar) == 164)
        #expect(LiveLearnSettingsPage.contentGutter(pane: 1014 - sidebar) == 131)
        #expect(LiveLearnSettingsPage.contentGutter(pane: 825 - sidebar) == 25)
        // The gutter is read from the whole pane (`SettingsView`), so a legacy scroller's 15 pt
        // comes out of the free side: the column still fits beside it on the minimum card.
        #expect(LiveLearnSettingsPage.contentGutter(pane: 825 - sidebar) + measure <= 825 - sidebar - 15)
    }

    /// 字幕外观's picture breaks out of the column to 24 pt from the pane's left edge, as far
    /// again on the right, and not at all where that would be less than a text step (the
    /// minimum card): never two left edges a point apart.
    @Test func theStageBreaksOutOnTheColumnsAxis() {
        let sidebar = LiveLearnSettingsPage.sidebarWidth
        #expect(AppearanceSettings.stageBreakout(gutter: 164) == 140)
        #expect(AppearanceSettings.stageBreakout(gutter: 131) == 107)
        #expect(AppearanceSettings.stageBreakout(gutter: 24) == 0)
        for width in 825...1080 {
            let pane = CGFloat(width) - sidebar
            let gutter = LiveLearnSettingsPage.contentGutter(pane: pane)
            let breakout = AppearanceSettings.stageBreakout(gutter: gutter)
            #expect(breakout == 0 || breakout >= 12, "\(width)")
            #expect(gutter - breakout >= 24, "\(width)")
            #expect(gutter + LiveLearnSettingsPage.contentMeasure + breakout <= pane - 24, "\(width)")
        }
    }

    /// Every one-line row is one height, whatever it carries at the rag — a value, an action, a
    /// shortcut binding, a menu, a switch, a row of words, a slider: the control is centred on
    /// the name's line and its own frame and target stay out of the layout. 40 pt: the 16 pt
    /// line and 12 above and below.
    @Test func everyOneLineRowIsOneHeight() throws {
        func height(_ view: some View) throws -> Int {
            try renderedImage(ThemedRoot(forced: .stellar) { view }.environment(\.staticRender, true)
                .frame(width: 576).fixedSize(horizontal: false, vertical: true), scale: 2).height
        }
        let value = try height(SettingRow("位置") { SettingValue("已保存") })
        #expect(value == 80)
        let rows: [(String, Int)] = [
            ("action", try height(SettingRow("位置") { Button("打开") {}.buttonStyle(SettingsActionStyle()) })),
            ("recorder", try height(SettingRow("显示 / 隐藏字幕") {
                ShortcutRecorder(action: .toggleOverlay, combo: nil, width: ShortcutBindingControl.bindingSlot) { _ in true }
            })),
            ("menu", try height(SettingRow("识别引擎") {
                PaperMenu(title: "Apple 本机", font: LLFont.body, color: nil, help: "识别引擎", items: { [] })
            })),
            ("switch", try height(SettingRow("始终不透明") {
                Toggle("始终不透明", isOn: .constant(true)).labelsHidden().toggleStyle(QuietSwitchStyle())
            })),
            ("segment", try height(SettingRow("字重") {
                TextSegment(options: [(0, "常规"), (1, "中等"), (2, "半粗")], selection: .constant(1))
            })),
            ("slider", try height(SettingRow("译文", layout: .wide) {
                QuietSlider(label: "译文字号", value: .constant(26), range: 18...40, step: 1) { "\(Int($0)) pt" }
            })),
        ]
        for (name, rowHeight) in rows { #expect(rowHeight == value, "\(name)") }
    }

    /// On paper the helper-shared star is the host `StarMark`'s paper rule, pixel for pixel, so
    /// a chosen settings word and a chosen menu row are one mark in the wilds too (the dark
    /// recipe is pinned by `Round12FoundationTests`).
    @Test func theSharedStarIsStarMarkOnPaper() throws {
        func render(_ view: some View, contrast: ColorSchemeContrast) throws -> CGImage {
            try renderedImage(ThemedRoot(forced: .wilds) { view }
                .environment(\._colorSchemeContrast, contrast)
                .padding(4).background(Color(hex: 0xF3EFDF)), scale: 4)
        }
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let host = try render(StarMark(), contrast: contrast)
            let shared = try render(SettingsStarPoint(dark: false), contrast: contrast)
            let diff = try pixelDiff(host, shared)
            #expect(diff.isUnchanged, "\(contrast): \(diff)")
        }
    }

    /// The rail's cut edge: nothing at rest, grows with what is hidden, never past 24 pt, all of
    /// it above the foot's rule.
    @Test func theRailEdgeFadeGrowsWithWhatIsHidden() {
        #expect(RailScrollEdge.band(0) == 0)
        #expect(RailScrollEdge.band(-12) == 0)
        #expect(RailScrollEdge.band(10) == 10)
        #expect(RailScrollEdge.band(400) == RailScrollEdge.fade)
        #expect(RailScrollEdge.fade == 24)
    }

    /// The selected page is shown clear of the fades. On the 960 × 600 window (825 × 528 card)
    /// the list has 398 pt above the foot's rule, where it is clipped: 主题's name (372–388)
    /// reaches into the 24 pt band that ends on the rule.
    @Test func theSelectedPageIsRevealedClearOfTheFade() {
        let window: CGFloat = 398
        let content = LiveLearnSettingsPage.listHeight(in: .developer)
        func center(_ page: LiveLearnSettingsPage) -> CGFloat { LiveLearnSettingsPage.railCenterY(page, mode: .developer) }
        func reveal(_ page: LiveLearnSettingsPage, from offset: CGFloat = 0) -> CGFloat {
            RailScrollEdge.offset(revealing: center(page), from: offset, window: window, content: content)
        }
        // Clear at rest: the list stays put.
        #expect(reveal(.sources) == 0)
        #expect(reveal(.engine) == 0)
        // Cut by the card: scrolled as little as clears it — 主题 by the 14 pt its name reaches
        // into the fade, 诊断 to the end of the list, where its row ends on the foot's rule.
        #expect(reveal(.theme) == 14)
        #expect(reveal(.theme) == center(.theme) + 8 - window + RailScrollEdge.fade)
        #expect(reveal(.shortcuts) == center(.shortcuts) + 8 - window + RailScrollEdge.fade)
        #expect(reveal(.diagnostics) == content - window)
        #expect(center(.diagnostics) + 16 - reveal(.diagnostics) == window)
        // Scrolled to the end, a row that went under the top fade comes back just below it, and
        // one that is clear does not move the list from under the pointer.
        let end = content - window
        #expect(reveal(.shortcuts, from: end) == end)
        #expect(reveal(.sources, from: end) == 0)
        #expect(reveal(.appearance, from: end) == center(.appearance) - 8 - RailScrollEdge.fade)
        // A list that fits never scrolls.
        #expect(RailScrollEdge.offset(revealing: center(.diagnostics), from: 0, window: 600, content: content) == 0)
    }

    /// Increase Contrast gives the dark theme's edgeless controls an edge: the switch's track
    /// (on, the accent at 45 %; off, a 1 pt `ink2` edge) reaches 3:1 against the ground, and a
    /// text well sunk in a sheet (the 词汇 editor's) is outlined by the lifted hairline. At
    /// normal contrast both stay as designed — no ring, no line round the well.
    @Test func increaseContrastEdgesTheDarkSwitchAndWell() throws {
        let theme = LLTheme.stellar
        /// WCAG relative luminance of an 8-bit sRGB colour.
        func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
            func linear(_ value: UInt8) -> Double {
                let s = Double(value) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        let ground = luminance(3, 4, 5)   // #030405
        /// The highest contrast against the ground along `xs` (2× pixels) on row `y`.
        func edge(_ view: some View, on background: Color, contrast: ColorSchemeContrast,
                  xs: ClosedRange<Int>, y: Int) throws -> Double {
            let image = try renderedImage(ThemedRoot(forced: theme) { view }
                .environment(\._colorSchemeContrast, contrast).environment(\.staticRender, true)
                .padding(8).background(background), scale: 2)
            let samples = try canonicalSamples(image)
            return xs.map { x in
                let i = (y * image.width + x) * 4
                let l = luminance(samples[i], samples[i + 1], samples[i + 2])
                return (max(l, ground) + 0.05) / (min(l, ground) + 0.05)
            }.max() ?? 1
        }
        // The 30 × 18 capsule spans x 16…76 and y 16…52 at 2×; the off knob sits at the left, so
        // the track's right end is its edge; the on knob sits at the right, so its left end is.
        let off = Toggle("关", isOn: .constant(false)).labelsHidden().toggleStyle(QuietSwitchStyle())
        let on = Toggle("开", isOn: .constant(true)).labelsHidden().toggleStyle(QuietSwitchStyle())
        #expect(try edge(off, on: theme.ground, contrast: .increased, xs: 72...75, y: 34) >= 3)
        #expect(try edge(off, on: theme.ground, contrast: .standard, xs: 72...75, y: 34) < 1.5)
        #expect(try edge(on, on: theme.ground, contrast: .increased, xs: 18...22, y: 34) >= 3)
        #expect(try edge(on, on: theme.ground, contrast: .standard, xs: 18...22, y: 34) < 2)
        // A 28 pt well on a sheet: its left edge is x 16…17 at 2×, halfway down at y 44.
        let well = QuietField(placeholder: "", text: .constant(""), fill: theme.ground).frame(width: 120)
        #expect(try edge(well, on: theme.surface, contrast: .increased, xs: 16...17, y: 44) >= 2)
        #expect(try edge(well, on: theme.surface, contrast: .standard, xs: 16...17, y: 44) < 1.2)
    }

    /// A group label with help is exactly as tall as one without: the "?" target is taken back
    /// out of the layout, so a section's rows do not drop by 14 pt when it has help.
    @Test func helpDoesNotChangeTheGroupLabelLine() throws {
        func height(_ view: some View) throws -> Int {
            try renderedImage(ThemedRoot(forced: .stellar) { view }.fixedSize(), scale: 2).height
        }
        let plain = try height(SettingsGroup("麦克风") { Color.clear.frame(width: 200, height: 1) })
        let helped = try height(SettingsGroup("麦克风", help: "说明") { Color.clear.frame(width: 200, height: 1) })
        #expect(plain == helped)
    }

    /// Opt-in review renders of what no fixture shows — 语音输入, the rail foot switched on at the
    /// minimum card, the 字幕外观 panes and 主题 on paper, a bound shortcut on paper:
    /// `LIVELEARN_R12_SETTINGS_GALLERY=<dir> swift test --filter Round12SettingsTests/gallery`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_R12_SETTINGS_GALLERY"] != nil))
    func gallery() throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["LIVELEARN_R12_SETTINGS_GALLERY"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ view: some View, _ name: String, theme: LLTheme, size: CGSize) throws {
            let root = ThemedRoot(forced: theme) { view }
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
                .environment(\.staticRender, true)
                .frame(width: size.width, height: size.height)
                .background(theme.ground)
            let image = try renderedImage(root, scale: 2)
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
        let suite = "LiveLearn.testing.r12-settings-gallery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: .empty())
        let card = SettingsView.size
        for theme in [LLTheme.stellar, .wilds] {
            let suffix = theme.isDark ? "dark" : "light"
            settings.settingsMode = .standard
            settings.requestedSettingsTab = .dictation
            try save(SettingsView().environment(model), "dictation-\(suffix)", theme: theme, size: card)
            settings.dictation.finalCorrection = true
            try save(DictationSettingsView().environment(model).padding(24), "dictation-refinement-\(suffix)", theme: theme,
                     size: CGSize(width: LiveLearnSettingsPage.contentMeasure + 48, height: 900))
            settings.dictation.finalCorrection = false
            settings.requestedSettingsTab = .theme
            try save(SettingsView().environment(model), "theme-\(suffix)", theme: theme, size: card)
            settings.setHotKey(KeyCombo(keyCode: 4, modifiers: KeyCombo.carbonModifiers([.command, .shift])), for: .toggleOverlay)
            settings.requestedSettingsTab = .shortcuts
            try save(SettingsView().environment(model), "shortcuts-\(suffix)", theme: theme, size: CGSize(width: card.width, height: 900))
            settings.setHotKey(nil, for: .toggleOverlay)
            for pane in [AppearancePane.layout, .behavior] {
                try save(AppearanceSettings(previewPane: pane).environment(model), "appearance-\(pane.rawValue)-\(suffix)", theme: theme, size: card)
            }
            // A preset in use (the star under its caption) and the caption placed at the top.
            OverlayAppearancePreset.paper.apply(to: settings)
            settings.overlayPlacement = .top
            try save(AppearanceSettings(previewPane: .text).environment(model), "appearance-preset-\(suffix)", theme: theme, size: card)
            settings.resetOverlayStyle()
            settings.overlayPlacement = .bottom
            settings.settingsMode = .developer
            settings.requestedSettingsTab = .diagnostics
            try save(SettingsView().environment(model), "developer-minimum-\(suffix)", theme: theme, size: CGSize(width: 825, height: 528))
        }
    }
}
