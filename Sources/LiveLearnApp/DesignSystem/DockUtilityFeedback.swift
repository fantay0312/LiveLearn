import SwiftUI

struct DockInteraction: Equatable {
    var hovered = false
    var pressed = false
    var reduceMotion = false
}

private struct DockInteractionKey: EnvironmentKey {
    static let defaultValue = DockInteraction()
}

private struct DockInteractionPreviewKey: EnvironmentKey {
    static let defaultValue: DockInteraction? = nil
}

extension EnvironmentValues {
    var dockInteraction: DockInteraction {
        get { self[DockInteractionKey.self] }
        set { self[DockInteractionKey.self] = newValue }
    }

    /// Used only by static renders, never by a live button.
    var dockInteractionPreview: DockInteraction? {
        get { self[DockInteractionPreviewKey.self] }
        set { self[DockInteractionPreviewKey.self] = newValue }
    }
}

struct DockUtilityIcon: View {
    enum Kind { case translation, settings }
    let kind: Kind
    @Environment(\.dockInteraction) private var interaction
    @Environment(\.staticRender) private var staticRender
    private var reduceMotion: Bool { interaction.reduceMotion }

    private var rotation: Double {
        guard kind == .settings, !reduceMotion else { return 0 }
        return interaction.pressed ? 8 : interaction.hovered ? 18 : 0
    }

    var body: some View {
        Image(systemName: kind == .settings ? "gearshape" : "character.bubble")
            .rotationEffect(.degrees(rotation))
            .offset(y: !reduceMotion && kind == .translation && interaction.hovered && !interaction.pressed ? -1.5 : 0)
            .scaleEffect(!reduceMotion && interaction.hovered && !interaction.pressed ? 1.08 : 1)
            .animation(reduceMotion || staticRender ? nil : .spring(response: 0.28, dampingFraction: 0.72), value: interaction)
            .accessibilityHidden(true)
    }
}

/// A feathered response with a transparent edge, rather than a standing button surface.
struct DockHoverLight: View {
    let active: Bool
    let pressed: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, geometry.size.height)
            RadialGradient(colors: [theme.ink.opacity(pressed ? 0.24 : 0.14),
                                    theme.ink.opacity(pressed ? 0.065 : 0.035), .clear],
                           center: .center, startRadius: 0, endRadius: side / 2)
                .frame(width: side, height: side)
                .scaleEffect(x: geometry.size.width / side, y: 1)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .opacity(active ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
