import SwiftUI

/// Feedback belongs to the control, not its layout. All surfaces share this short press
/// and release; keyboard focus keeps the native outline and Reduce Motion keeps geometry still.
struct ControlPressFeedback: ViewModifier {
    let pressed: Bool
    var enabled = true
    var scale: CGFloat = 0.98
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsInteractionEnabled) private var inSettings

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && enabled && !reduceMotion ? (inSettings ? min(scale, 0.96) : scale) : 1)
            .offset(y: inSettings && pressed && enabled && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : inSettings
                       ? (pressed ? .easeOut(duration: 0.07) : .spring(response: 0.26, dampingFraction: 0.74))
                       : LLMotion.press(false, down: pressed), value: pressed)
    }
}

/// Bare controls retain the stellar navigation's unboxed appearance. Small icon actions
/// receive a real hit area, a pointer response, and a focus shape without moving neighbours.
struct InlineButtonStyle: ButtonStyle {
    var icon = false
    var hoverFill = false

    func makeBody(configuration: Configuration) -> some View {
        FeedbackBody(configuration: configuration, icon: icon, hoverFill: hoverFill)
    }

    private struct FeedbackBody: View {
        let configuration: Configuration
        let icon: Bool
        let hoverFill: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.settingsInteractionEnabled) private var inSettings
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(minWidth: icon ? 28 : nil, minHeight: 28)
                .background(hoverFill && enabled && hovering ? theme.fillHover : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .background {
                    if inSettings && !hoverFill {
                        SettingsInteractionLight(color: theme.ink, active: enabled && (hovering || configuration.isPressed),
                                                 pressed: configuration.isPressed)
                    }
                }
                .opacity(enabled ? (configuration.isPressed ? 0.68 : (hovering ? 1 : 0.88)) : 0.4)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6))
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
        }
    }
}

/// The glyph action (round 12, the third of the three action grammars): a bare regular-weight
/// SF Symbol — ✕, ⓘ, +, ··· — with no fill, no plate and no hover block. It rests in `ink2` and
/// lifts to `ink` under the pointer, the way a nav word brightens; a semantic `tint` (brick)
/// keeps its colour and answers with the press alone. The hit area is at least 28 × 28 (§11).
///
/// `flush: .trailing` puts the glyph's own edge on the caller's rag (the popover's ✕ and ⓘ line
/// up with the switches and the 取消 word above and below them); the hit area then extends
/// inward from the rag instead of hanging past it. Press is 55 % with the shared press scale.
struct GlyphButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var flush: HorizontalEdge? = nil

    func makeBody(configuration: Configuration) -> some View {
        GlyphBody(configuration: configuration, tint: tint, flush: flush)
    }

    private struct GlyphBody: View {
        let configuration: Configuration
        let tint: Color?
        let flush: HorizontalEdge?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(theme.actionInk(tint: tint, hovering: hovering, enabled: enabled))
                .frame(minWidth: 28, minHeight: 28, alignment: alignment)
                .opacity(configuration.isPressed && enabled ? 0.55 : 1)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
        }

        private var alignment: Alignment {
            switch flush {
            case .leading: return .leading
            case .trailing: return .trailing
            case nil: return .center
            }
        }
    }
}
