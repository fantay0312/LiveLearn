import SwiftUI

/// Bare navigation and quiet utility actions, with transient feedback instead of a standing plate.
/// A resting label is the quiet ink (`HomeInk.value`: ink2, one step up under Increase Contrast);
/// full ink is for the selected page or mode and for a label being touched.
struct DockButtonStyle: ButtonStyle {
    var selected = false
    var utility = false

    func makeBody(configuration: Configuration) -> some View {
        DockButtonBody(configuration: configuration, selected: selected, utility: utility)
    }

    private struct DockButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        let utility: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.staticRender) private var staticRender
        @Environment(\.dockInteractionPreview) private var preview
        @State private var hovering = false

        private var previewState: DockInteraction? { utility && staticRender ? preview : nil }
        private var motionReduced: Bool { previewState?.reduceMotion ?? reduceMotion }
        private var pressed: Bool { enabled && (previewState?.pressed ?? configuration.isPressed) }
        private var highlighted: Bool { enabled && (previewState?.hovered ?? hovering) }
        private var stationary: Bool { motionReduced || (staticRender && previewState == nil) }
        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

        var body: some View {
            configuration.label
                .environment(\.dockInteraction, DockInteraction(hovered: highlighted, pressed: pressed, reduceMotion: motionReduced))
                .foregroundStyle(enabled ? (selected || highlighted || pressed ? theme.ink : HomeInk(theme).value) : theme.inkDisabled)
                .opacity(enabled ? (pressed ? (utility ? 0.86 : 0.72) : 1) : 0.45)
                .background {
                    if utility { DockHoverLight(active: highlighted || pressed, pressed: pressed) }
                }
                .scaleEffect(stationary ? 1 : pressed ? (utility ? 0.95 : 0.92) : highlighted && !utility ? 1.035 : 1)
                .offset(y: stationary ? 0 : pressed ? 1 : 0)
                .animation(motionReduced || staticRender ? nil : pressed ? .easeOut(duration: 0.07)
                           : .spring(response: 0.28, dampingFraction: utility ? 0.74 : 0.68), value: pressed)
                .animation(LLMotion.hover(motionReduced || staticRender), value: highlighted)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, shape)
                .onHover { hovering = $0 }
        }
    }
}
