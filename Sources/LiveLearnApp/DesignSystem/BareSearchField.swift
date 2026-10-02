import SwiftUI

/// Search on the ground (round 12): a 13 pt magnifier and the placeholder written straight on
/// the page, over one 0.5 pt rule that fades at its far end — no fill, no box, no system ring.
/// In-window structures carry no edge and no fill; the rule is all that says "this line takes
/// text", like the ruled line on a form printed on paper.
///
/// - Hover lifts the rule to the full `hairline`; focus draws it as a 1 pt `ink2` line, still
///   fading at its far end. Colour and weight only: the rule lives in a fixed 1 pt slot under
///   the text, so nothing moves.
/// - Under Increase Contrast the system focus ring is left on as well (`QuietField`'s rule).
/// - While there is text, a bare 10 pt `xmark` glyph clears it (28 pt hit area) and puts the
///   cursor back; Esc clears too. The field is flush: its magnifier sits on the caller's text
///   column and the rule runs to the caller's edge, so callers inset it with padding.
/// - Offscreen (`staticRender`) the field is a `Text` stand-in, since `TextField` does not draw.
///
/// `focus` is the caller's, so ⌘F or a clear action elsewhere can put the cursor in it; without
/// one the field keeps its own.
struct BareSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// VoiceOver name of the field ("搜索翻译记录").
    var accessibilityName: String? = nil
    /// VoiceOver name of the clear glyph ("清除记录搜索").
    var clearName = "清除搜索"
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var ownFocus: Bool
    @State private var hovering = false

    static let height: CGFloat = 28

    var body: some View {
        HStack(spacing: LLMetrics.space(2)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(theme.ink3)
                .accessibilityHidden(true)
            if staticRender {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? theme.ink3 : theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(theme.ink3))
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.ink)
                    .focused(focus ?? $ownFocus)
                    .focusEffectDisabled(contrast != .increased)
                    .onExitCommand { text = "" }
                    .onSubmit { onSubmit?() }
                    .accessibilityLabel(accessibilityName ?? placeholder)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    (focus ?? $ownFocus).wrappedValue = true
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: .trailing))
                .accessibilityLabel(clearName)
            }
        }
        .font(LLFont.body)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) { Underline(focused: hasFocus, hovering: hovering) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(LLMotion.hover(reduceMotion), value: hasFocus)
        .animation(LLMotion.hover(reduceMotion), value: hovering)
    }

    private var hasFocus: Bool { !staticRender && (focus?.wrappedValue ?? ownFocus) }

    /// Resting: the settings rule (the full `hairline` under the pointer). Focused: a 1 pt
    /// `ink2` line, still fading at its far end. Its own view so review renders, which cannot
    /// focus a field, can show the focused line.
    struct Underline: View {
        var focused: Bool
        var hovering = false
        @Environment(\.theme) private var theme

        var body: some View {
            ZStack(alignment: .bottom) {
                FadingRule(strength: hovering || theme.raisesContrast ? 1 : 0.55)
                    .opacity(focused ? 0 : 1)
                LinearGradient(stops: [.init(color: theme.ink2, location: 0), .init(color: theme.ink2, location: 0.9),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .opacity(focused ? 1 : 0)
            }
            .frame(height: 1, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }
}
