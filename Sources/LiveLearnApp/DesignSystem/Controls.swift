import SwiftUI

/// Design language §5.1 (round 12): three action grammars, none of them boxed or filled.
///
/// - `CompactCapsuleButtonStyle` (CompactCapsule.swift): the one commit of a sheet or popover.
/// - `TextButtonStyle` / `InlineButtonStyle` / `SettingsActionStyle`: every other action, a
///   bare word that answers the pointer (保存 / 导出 / 重新检查). A word resting in `ink2` lifts
///   to `ink`; one already resting in `ink` — `TextButtonStyle(strong:)`, the way forward under a
///   sentence, and Settings' actions — answers with a transient light instead.
/// - `GlyphButtonStyle` (Interaction.swift): bare regular-weight SF Symbols, ≥ 28 pt hit area.
///
/// A word that is on or off (`TextToggleStyle`) is not an action: its ink and its star are its
/// state.
///
/// Hover state lives inside the style body as `@State`; nothing here reads the model, so a
/// pointer moving over a button re-evaluates that button and nothing else.

/// Press dimming, with the settings surface's stronger spatial response when scoped there.
struct PressDimStyle: ButtonStyle {
    var dim: Double = 0.55
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsInteractionEnabled) private var inSettings

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if inSettings {
            configuration.label
                .opacity(configuration.isPressed ? dim : 1)
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, scale: 0.96))
        } else {
            configuration.label
                .opacity(configuration.isPressed ? dim : 1)
                .animation(LLMotion.hover(reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Reports the pressed state out to the view so a whole mark can react, without the style
/// deciding anything about looks.
struct PressReporting: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

struct TextButtonStyle: ButtonStyle {
    /// A semantic color (brick for a destructive action) instead of the ink2 → ink pair.
    var tint: Color? = nil
    /// At the right end of a settings row the word aligns with the values above and below it:
    /// no side padding, the 6pt hit margin is kept outside the glyphs.
    var flush = false
    /// The way forward under a 13/400 `ink2` sentence (an empty page's 前往首页, the source
    /// check's remedy): 13/500 in `ink` at rest, so colour and weight both set it apart from the
    /// copy it answers — at the sentence's own size, weight and ink it read as a third line of
    /// that copy. A word already at `ink` cannot brighten, so the pointer answers with the same
    /// transient light as Settings' 13/500 `ink` actions (`SettingsActionStyle`): the neutral
    /// `ink` `SettingsInteractionLight`, 10 pt past the glyphs each side, stronger under the
    /// press — so every 13/500 `ink` action in the app answers the pointer the same way.
    var strong = false
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration, theme: theme, enabled: enabled, tint: tint, flush: flush, strong: strong)
    }

    private struct TextButtonBody: View {
        let configuration: Configuration
        let theme: LLTheme
        let enabled: Bool
        let tint: Color?
        let flush: Bool
        let strong: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = enabled && configuration.isPressed
            configuration.label
                .font(strong ? LLFont.bodyStrong : LLFont.body)
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, flush ? 0 : 6)
                .frame(height: LLMetrics.controlHeight)
                .background {
                    if strong {
                        // 10 pt past the glyphs each side, whatever the side padding: on the
                        // word's own box the light would fade out under the glyphs.
                        SettingsInteractionLight(color: theme.ink, active: pressed || (enabled && hovering), pressed: pressed)
                            .padding(.horizontal, flush ? -10 : -4)
                    }
                }
                .opacity(pressed ? 0.55 : 1)
                .contentShape(Rectangle().inset(by: flush ? -6 : 0))
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous).inset(by: flush ? -6 : 0))
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled, scale: 0.99))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
                .animation(LLMotion.hover(reduceMotion), value: configuration.isPressed)
        }

        private var color: Color {
            theme.actionInk(tint: tint ?? (strong ? theme.ink : nil), hovering: hovering, enabled: enabled)
        }
    }
}

extension LLTheme {
    /// The ink of a bare action — a `TextButtonStyle` word or a `GlyphButtonStyle` glyph, which
    /// answer the pointer the same way. The resting ink (`ink2`, or a quiet `ink3` the caller
    /// names) lifts to `ink` under the pointer; a semantic tint (brick) keeps its colour and
    /// answers with the press alone; disabled is one token.
    func actionInk(tint: Color?, hovering: Bool, enabled: Bool) -> Color {
        guard enabled else { return inkDisabled }
        let rest = tint ?? ink2
        let lifts = tint == nil || tint == ink2 || tint == ink3
        return hovering && lifts ? ink : rest
    }
}

/// A word that is on or off (§5.1, 0.4; round 12): "字幕" and "锁定" beside the status line. On,
/// the word is written in `ink` and a star point is stamped under it — the mark every chosen
/// word carries, and the one Home's 字幕 wears (`CaptionWordToggleStyle`), so the one overlay
/// switch reads the same on both pages. Off, full `ink3` (≥ 4.5 : 1 on either ground — at 60 %
/// it fell to ≈ 3 : 1; the settings rail foot's 开发者模式 made the same call); the pointer lifts
/// an off word to `ink2` so it still reads as something to press. Colour and the star, never
/// weight, and the star is an overlay: the bar does not shift when a word is pressed. Same 28 pt
/// hit height as `TextButtonStyle`.
struct TextToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(TextToggleButtonStyle(on: configuration.isOn))
            .accessibilityValue(configuration.isOn ? "开" : "关")
            .accessibilityAddTraits(.isToggle)
    }
}

/// `TextToggleStyle`'s word for a control that must stay a button: 目录 names its action
/// (显示 / 收起记录栏) and owns ⌘⇧L, so it keeps a button's semantics and takes only the look.
struct TextToggleButtonStyle: ButtonStyle {
    let on: Bool

    func makeBody(configuration: Configuration) -> some View {
        TextToggleBody(configuration: configuration, on: on)
    }

    private struct TextToggleBody: View {
        let configuration: Configuration
        let on: Bool
        @State private var hovering = false
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

        var body: some View {
            configuration.label
                .font(LLFont.body)
                .foregroundStyle(color)
                // Differentiate Without Color: the on word also carries a rule, which never
                // moves it.
                .underline(withoutColor && on, color: theme.ink)
                .lineLimit(1)
                .starMarked(on)
                .padding(.horizontal, 6)
                .frame(height: LLMetrics.controlHeight)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
                // The hover lifts with a short fade; the on / off change itself is instant (the
                // star is stamped, never faded), since it is as often typed (⌘⇧H, the global
                // key) as clicked.
                .animation(LLMotion.hover(reduceMotion), value: hovering)
                .animation(LLMotion.hover(reduceMotion), value: configuration.isPressed)
        }

        private var color: Color {
            guard enabled else { return theme.inkDisabled }
            if on { return theme.ink }
            if hovering { return theme.ink2 }
            return theme.ink3
        }
    }
}

/// Text-only row button for the menu bar panel: a soft tint under the pointer, a little more
/// when pressed, nothing at rest.
struct RowButtonStyle: ButtonStyle {
    var inset: CGFloat = LLMetrics.space(3)
    var radius: CGFloat = LLMetrics.Radius.control
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration, theme: theme, inset: inset, radius: radius)
    }

    private struct RowButtonBody: View {
        let configuration: Configuration
        let theme: LLTheme
        let inset: CGFloat
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        // No fade on rows: a pointer sweeping down a list would leave a trail of half-tinted
        // rows, and selection moves by keyboard as often as by click. Instant, like a menu.
        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
                .frame(minHeight: 30)
                .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed && enabled { return theme.fillPressed }
            if hovering && enabled { return theme.fillHover }
            return .clear
        }
    }
}

/// The 2pt accent mark (ice / forest) that means "此刻": the open sentence in the transcript,
/// the live session in the sidebar. Fades rather than moves.
struct NowMark: View {
    var visible: Bool = true
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Rectangle()
            .fill(theme.accent)
            .frame(width: 2)
            .opacity(visible ? 1 : 0)
            .animation(LLMotion.finalize(reduceMotion), value: visible)
            .accessibilityHidden(true)
    }
}

/// A line of short facts that wraps only when it must (a long app or device name), instead of
/// squeezing its neighbours. Items keep their natural size; rows are `rowSpacing` apart.
struct FlowRow: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
