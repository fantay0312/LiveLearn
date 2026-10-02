import SwiftUI

/// 字幕外观 › 文字. The presets first, as three equal columns under a "预设" label — each a
/// specimen in the preset's own face with its name under it, both on the column's left edge,
/// and the stamped point of light under the name of the preset in use ("自定样式" at the label's
/// right end when none is). Then the rows, notes under their names; 对比与描边 folds with the
/// app's one disclosure row (`DictationFold`), not the system triangle.
struct OverlayReadabilitySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var advanced = false

    /// From the top of a preset column to its specimen's baseline: the system face's ascent at
    /// 17 pt, so with that face the column stands where its line box used to.
    private static let specimenBaseline: CGFloat = 17
    /// From the specimen's baseline to the top of its caption: the system face's descent and
    /// the 6 pt that separated the two boxes.
    private static let captionDrop: CGFloat = 10

    var body: some View {
        @Bindable var s = model.settings
        let custom = !OverlayAppearancePreset.allCases.contains(where: { $0.matches(s) })
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("预设").font(LLFont.labelStrong).foregroundStyle(theme.ink2)
                Spacer()
                if custom { Text("自定样式").font(LLFont.label).foregroundStyle(theme.ink3) }
            }
            // The specimens' CJK glyphs stand taller than their line box, so the label needs a
            // full step of air to clear them.
            .padding(.bottom, LLMetrics.space(4))
            HStack(alignment: .top, spacing: LLMetrics.space(4)) {
                ForEach(OverlayAppearancePreset.allCases) { preset in
                    let selected = preset.matches(s)
                    Button { preset.apply(to: s) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            // The three faces have line boxes of different heights, so each
                            // specimen hangs from one baseline fixed for all three columns
                            // instead of stacking by its box: the specimens share a line, and
                            // so do the captions and the star under the chosen one.
                            Color.clear.frame(height: Self.specimenBaseline)
                                .overlay(alignment: .bottomLeading) {
                                    Text("你好，Hello").font(Font(OverlayTypography.nativeFont(family: preset.family, size: 17, weight: .regular)))
                                        .foregroundStyle(preset.isAvailable ? theme.ink : theme.inkDisabled)
                                        .fixedSize()
                                        .alignmentGuide(.bottom) { $0[.firstTextBaseline] }
                                }
                            Text(preset.label).font(LLFont.label)
                                .foregroundStyle(preset.isAvailable ? (selected ? theme.ink : theme.ink2) : theme.inkDisabled)
                                // On the caption's text box: see `SettingsStarPoint`.
                                .overlay(alignment: .bottom) { if selected { SettingsStarPoint(dark: theme.isDark, stamped: true) } }
                                .padding(.top, Self.captionDrop)
                        }
                        .padding(.bottom, LLMetrics.space(3))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(InlineButtonStyle()).help(preset.isAvailable ? preset.note : "本机未安装楷体字体")
                        .disabled(!preset.isAvailable)
                        .accessibilityLabel(preset.label)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.bottom, LLMetrics.space(4))
            SettingsSheet {
                SettingRow("字体", note: missingFontNote(s)) {
                    PaperMenu(title: OverlayTypography.label(s.overlayFontFamily), help: "选择字幕字体") {
                        [.row("系统字体", selected: s.overlayFontFamily.isEmpty) { s.overlayFontFamily = "" },
                         .section("本机字体")] + OverlayTypography.families.map { family in
                            .row(OverlayTypography.label(family), id: family, selected: s.overlayFontFamily == family) {
                                s.overlayFontFamily = family
                            }
                        }
                    }.frame(maxWidth: 260, alignment: .trailing)
                }
                SheetDivider()
                SettingRow("译文", layout: .wide) {
                    HStack(spacing: 14) {
                        QuietSlider(label: "译文字号", value: $s.captionTargetSize, range: 18...40, step: 1) { "\(Int($0)) pt" }
                        QuietColorWell(label: "译文颜色", color: Binding(
                            get: { HexColor.color(s.overlayTextHex, fallback: LLOverlay.text) },
                            set: { s.overlayTextHex = HexColor.hex(from: $0) }))
                    }
                }
                SheetDivider()
                SettingRow("字重") {
                    TextSegment(options: OverlayTextWeight.allCases.map { ($0, $0.label) }, selection: $s.overlayTextWeight, label: "译文字重")
                }
                SheetDivider()
                SettingRow("原文", layout: .wide) {
                    HStack(spacing: 14) {
                        QuietSlider(label: "原文字号", value: $s.captionSourceSize, range: 12...28, step: 1) { "\(Int($0)) pt" }
                        QuietColorWell(label: "原文颜色", color: Binding(
                            get: { HexColor.color(s.overlaySourceHex.isEmpty ? s.overlayTextHex : s.overlaySourceHex, fallback: LLOverlay.text2) },
                            set: { s.overlaySourceHex = HexColor.hex(from: $0) }))
                    }.disabled(!s.showSourceInOverlay || s.captionPresentation == .singleLine)
                }
                // The 原文 row's note, with the one action it offers: it sits where a row note
                // sits (just under the name, inside the row's rule) rather than as a free line.
                HStack(alignment: .firstTextBaseline) {
                    SettingsNote(s.captionPresentation == .singleLine ? "单行模式仅显示译文，原文设置在分层模式中保留。" : s.showSourceInOverlay ? (s.overlaySourceHex.isEmpty ? "原文颜色跟随译文" : "原文使用独立颜色") : "原文已隐藏，可在「显示与行为」中开启")
                    Spacer()
                    if !s.overlaySourceHex.isEmpty {
                        Button("跟随译文") { s.overlaySourceHex = "" }.buttonStyle(SettingsActionStyle())
                    }
                }
                .padding(.top, -LLMetrics.space(2)).padding(.bottom, LLMetrics.space(3))
                SheetDivider()
                DictationFold(title: "对比与描边", summary: s.overlayContrastMode.label, expanded: $advanced) {
                    SettingsSheet {
                        SettingRow("对比模式", note: s.overlayContrastMode == .automatic ? "浅色画面使用深色实心字，深色画面恢复原字色；短暂闪光不会立刻切换。" : "自定描边；设为 0 可关闭。") {
                            TextSegment(options: OverlayContrastMode.allCases.map { ($0, $0.label) },
                                        selection: $s.overlayContrastMode, label: "字幕对比模式")
                        }
                        if s.overlayContrastMode == .manual {
                            SheetDivider()
                            SettingRow("描边", layout: .wide) {
                                HStack(spacing: 14) {
                                    QuietSlider(label: "描边宽度", value: $s.overlayOutlineWidth, range: 0...3, step: 0.25) { String(format: "%.2g pt", $0) }
                                    QuietColorWell(label: "描边颜色", color: Binding(
                                        get: { HexColor.color(s.overlayOutlineHex, fallback: .black) },
                                        set: { s.overlayOutlineHex = HexColor.hex(from: $0) }))
                                }
                            }
                        }
                    }
                }
            }
            CaptionAutoContrastPermission()
                .padding(.top, LLMetrics.space(3))
        }
    }

    /// When the chosen face is missing: the preference is kept and the system face stands in.
    private func missingFontNote(_ s: AppSettings) -> String? {
        guard !s.overlayFontFamily.isEmpty, !OverlayTypography.families.contains(s.overlayFontFamily),
              NSFont(name: s.overlayFontFamily, size: 26) == nil else { return nil }
        return "原选字体未安装，暂用系统字体；保留原选择。"
    }
}
