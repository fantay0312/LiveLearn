import SwiftUI

/// A breathing play mark with a generous hit target; the name and shortcut live in its hint.
struct SessionStartButton: View {
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.circle")
                .font(.system(size: 34, weight: .regular))
                .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: enabled && !reduceMotion && !staticRender)
                .foregroundStyle(enabled ? theme.accent : theme.inkDisabled)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
                .scaleEffect(hovering && enabled ? 1.06 : 1)
        }
        .buttonStyle(PressDimStyle())
        .onHover { hovering = $0 }
        .animation(LLMotion.hover(reduceMotion), value: hovering)
        .accessibilityLabel("开始翻译")
    }
}
