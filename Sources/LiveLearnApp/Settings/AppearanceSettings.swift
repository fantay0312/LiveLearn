import SwiftUI
import CaptionDomain

enum AppearancePane: String, CaseIterable, Identifiable {
    case text, layout, behavior
    var id: String { rawValue }
    var label: String {
        switch self { case .text: "文字"; case .layout: "背景与布局"; case .behavior: "显示与行为" }
    }
}

/// A stationary stage above a short, independently scrolling inspector. Controls are
/// grouped by the decision being made; switching a pane never hides the resulting caption.
/// The pane switcher is the settings row of words (`TextSegment`: a stamped point of light
/// under the chosen one) standing on the horizon rule; the inspector is unboxed `SettingRow`s
/// with fading rules, decision groups 32 pt apart like every other page.
///
/// Everything on the page sits on the same 576 pt measure, in the same place, as every other
/// settings page (`SettingsView` hands down the gutter), so the title, 恢复默认, the rules and the
/// right rag line up when the sidebar switches pages — the stage's own row of scene words with
/// 播放, and its line of facts, included. Only the stage's picture is wider: it shows a caption at
/// something like its real width, so it breaks out of the column by the same amount either side
/// (`stageBreakout`), a figure centred on the column's axis whose captions keep the column's two
/// edges. The page has one axis and one right edge.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.settingsContentGutter) private var gutter
    @State private var pane: AppearancePane = .text
    var previewPane: AppearancePane = .text

    /// How far the stage's picture reaches past the column on each side: to 24 pt from the
    /// pane's left edge, and as far again on the right, so it stays centred on the column even
    /// where the ✕ pins the column off-centre (140 pt on the 1080 pt card, 107 on the default
    /// 1014 one). Under a text step of breakout (cards narrower than 836 pt) the picture is the
    /// column's width instead: the 1 pt it would reach out on the 825 pt minimum card read as
    /// two left edges that nearly meet.
    static func stageBreakout(gutter: CGFloat) -> CGFloat {
        let breakout = gutter - LLMetrics.space(5)
        return breakout < LLMetrics.space(3) ? 0 : breakout
    }

    var body: some View {
        @Bindable var settings = model.settings
        let shownPane = Binding(get: { staticRender ? previewPane : pane }, set: { pane = $0 })
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SettingsPageTitle(text: "字幕外观")
                Spacer()
                Button("恢复默认") { model.settings.resetOverlayStyle() }
                    .buttonStyle(SettingsActionStyle()).help("恢复字体、颜色、字号与浮层样式")
            }
            .padding(.bottom, LLMetrics.space(5))
            .onColumn(gutter)
            // A section label over its two words, like every group on every page; it used to
            // sit on the words' own line and read as a third option.
            VStack(alignment: .leading, spacing: LLMetrics.space(1)) {
                Text("字幕呈现").font(LLFont.labelStrong).foregroundStyle(theme.ink2)
                TextSegment(options: CaptionPresentation.allCases.map { ($0, $0.label) },
                            selection: $settings.captionPresentation, label: "字幕呈现方式")
                SettingsNote(settings.captionPresentation.note)
            }
            .padding(.bottom, LLMetrics.space(5))
            .onColumn(gutter)
            AppearanceCaptionStage(breakout: Self.stageBreakout(gutter: gutter))
                .padding(.bottom, LLMetrics.space(3))
                .onColumn(gutter)
            VStack(alignment: .leading, spacing: 0) {
                TextSegment(options: AppearancePane.allCases.map { ($0, $0.label) }, selection: shownPane, label: "字幕外观分区")
                SettingsRule()
            }
            .onColumn(gutter)
            ScrollViewReader { proxy in
                ScrollContainer(showsIndicators: true) {
                    Group {
                        switch shownPane.wrappedValue {
                        case .text: OverlayReadabilitySettings()
                        case .layout: layoutControls
                        case .behavior: behaviorControls
                        }
                    }
                    .padding(.top, LLMetrics.space(5)).padding(.bottom, LLMetrics.space(5)).id("appearance-controls")
                    .onColumn(gutter)
                }
                // The same dissolving edge as every other page's column: the inspector is the
                // part of this page the card cuts.
                .mask { SettingsScrollEdge(fade: SettingsView.scrollEdgeFade) }
                .onChange(of: pane) { _, _ in proxy.scrollTo("appearance-controls", anchor: .top) }
            }
        }
        .padding(.top, SettingsView.contentTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var layoutControls: some View {
        @Bindable var s = model.settings
        return VStack(alignment: .leading, spacing: LLMetrics.space(6)) {
            SettingsGroup {
                SettingRow("背景颜色") {
                    QuietColorWell(label: "底色", color: Binding(get: { HexColor.color(s.overlayBackgroundHex, fallback: .black) },
                        set: { s.overlayBackgroundHex = HexColor.hex(from: $0) }))
                }
                SheetDivider()
                SettingRow("不透明度", layout: .wide) {
                    QuietSlider(label: "背景不透明度", value: $s.overlayOpacity, range: 0...1, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                        .disabled(s.overlayOpaque)
                }
                SheetDivider()
                SettingRow("始终不透明", note: "0% 只显示文字。系统减少透明度或增强对比度时使用不透明背景。") {
                    Toggle("始终不透明", isOn: $s.overlayOpaque).labelsHidden().toggleStyle(QuietSwitchStyle())
                }
            }
            SettingsGroup {
                SettingRow("字幕宽度", layout: .wide) {
                    QuietSlider(label: "浮层宽度", value: $s.captionDisplayWidth, range: 480...1400, step: 10) { "\(Int($0)) pt" }
                }
                SheetDivider()
                SettingRow("文字对齐") {
                    TextSegment(options: OverlayTextAlignment.allCases.map { ($0, $0.label) }, selection: $s.overlayTextAlignment, label: "字幕文字对齐")
                }
                SheetDivider()
                SettingRow("行距") {
                    TextSegment(options: OverlayLineSpacing.allCases.map { ($0, $0.label) }, selection: $s.overlayLineSpacing, label: "字幕行距")
                }.disabled(s.captionPresentation == .singleLine)
                SheetDivider()
                SettingRow("默认位置", note: "浮层可直接拖动；超出屏幕时自动收窄。") {
                    TextSegment(options: OverlayPlacement.allCases.map { ($0, $0.label) }, selection: $s.overlayPlacement, label: "默认位置")
                }
            }
        }
    }

    private var behaviorControls: some View {
        @Bindable var s = model.settings
        return VStack(alignment: .leading, spacing: LLMetrics.space(6)) {
            SettingsGroup {
                SettingRow("显示原文") { Toggle("显示原文", isOn: $s.showSourceInOverlay).labelsHidden().toggleStyle(QuietSwitchStyle()) }
                    .disabled(s.captionPresentation == .singleLine)
                SheetDivider()
                SettingRow("上一句译文") { Toggle("显示上一句译文", isOn: $s.showPreviousLine).labelsHidden().toggleStyle(QuietSwitchStyle()) }
                    .disabled(s.captionPresentation == .singleLine)
                SheetDivider()
                SettingRow("呼吸线") { Toggle("显示呼吸线", isOn: $s.showBreathLine).labelsHidden().toggleStyle(QuietSwitchStyle()) }
                    .disabled(s.captionPresentation == .singleLine)
            }
            SettingsGroup {
                SettingRow("字幕稳定度", note: s.stability.note) {
                    TextSegment(options: CaptionStability.allCases.map { ($0, $0.label) }, selection: $s.stability, label: "稳定度预设")
                }
            }
            SettingsGroup {
                SettingRow("关闭字幕时控制会话", note: s.controlSessionOnOverlayClose ? nil : "仅隐藏字幕，监听与翻译继续。") {
                    Toggle("关闭字幕时暂停或结束会话", isOn: $s.controlSessionOnOverlayClose).labelsHidden().toggleStyle(QuietSwitchStyle())
                }
                if s.controlSessionOnOverlayClose {
                    SheetDivider()
                    SettingRow("关闭后", note: s.overlayCloseAction.note) {
                        TextSegment(options: OverlayCloseAction.allCases.map { ($0, $0.label) }, selection: $s.overlayCloseAction, label: "关闭字幕后的会话操作")
                    }
                }
            }
            SettingsGroup {
                SettingRow("主窗口使用衬线字体", note: "只影响主窗口记录区。重新显示字幕不会自动开始或继续会话。") {
                    Toggle("阅读模式使用衬线字体", isOn: $s.readingSerif).labelsHidden().toggleStyle(QuietSwitchStyle())
                }
            }
        }
    }
}

private extension View {
    /// On the page's column: 576 pt at the pane's gutter, as on every other settings page. A
    /// part that breaks out of it (the stage's picture) widens itself with negative padding
    /// inside, so the column's frame, and everything aligned to it, stays put.
    func onColumn(_ gutter: CGFloat) -> some View {
        frame(maxWidth: LiveLearnSettingsPage.contentMeasure, alignment: .leading)
            .padding(.leading, gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
