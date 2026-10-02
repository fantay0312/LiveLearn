import SwiftUI

/// The orb owns the motion. Its transport marks share the same round ink particles.
struct ParticleTransportButton: View {
    enum Glyph { case pause, play, stop }
    let glyph: Glyph
    let title: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Canvas { context, size in
                    let step: CGFloat = 4.8
                    let radius: CGFloat = 1.35
                    for row in 0..<7 {
                        for column in 0..<7 where contains(row: row, column: column) {
                            let x = size.width / 2 + CGFloat(column - 3) * step
                            let y = size.height / 2 + CGFloat(row - 3) * step
                            context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                         with: .color(enabled ? theme.ink : theme.inkDisabled))
                        }
                    }
                }
                .frame(width: 62, height: 62)
                .background(hovering && enabled ? theme.fill : .clear, in: Circle())
                .overlay { Circle().strokeBorder(hovering ? theme.ink3 : theme.hairline, lineWidth: 1) }
                Text(title).font(LLFont.label).foregroundStyle(enabled ? theme.ink2 : theme.inkDisabled)
            }
            .frame(width: 82).contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .onHover { hovering = $0 }
        .animation(LLMotion.hover(reduceMotion), value: hovering)
        .accessibilityLabel(title)
    }

    private func contains(row: Int, column: Int) -> Bool {
        switch glyph {
        case .pause: return column == 1 || column == 2 || column == 4 || column == 5
        case .stop: return (1...5).contains(row) && (1...5).contains(column)
        case .play: return column >= 1 && column <= 6 - abs(row - 3) * 2
        }
    }
}
