import SwiftUI

/// Session transport (§5.1, 0.3): the marks that start, pause, resume and stop a session,
/// drawn in the product's own strokes rather than borrowed from a media player.
///
/// - `start`: a 14 × 16 accent triangle (ice / forest) at the head of the resting sound lines;
///   pressing it is what sets them moving. The only accent in the bar before a session. Tinted
///   (beside a finished session or a record) it takes the resume mark's 10 × 12, level with the
///   pause bars and the stop square.
/// - `pause`: two 2pt ink bars, the same stroke as the "此刻" mark beside the open sentence.
/// - `play`: a smaller accent triangle; resuming is the one accent action while paused.
/// - `stop`: a 10pt square with a 2pt corner, in the quiet ink.
///
/// No fill, no ring, no border: the mark darkens under the pointer and dims when pressed,
/// like the text buttons beside it. The hit area is the full 28pt control height.
enum TransportGlyph {
    case start, pause, play, stop

    var accessibilityLabel: String {
        switch self {
        case .start: return "开始"
        case .pause: return "暂停"
        case .play: return "继续"
        case .stop: return "停止"
        }
    }
}

struct TransportButton: View {
    let glyph: TransportGlyph
    var help: String? = nil
    var shortcut: KeyboardShortcut? = nil
    /// Read by VoiceOver after the label: the shortcut, or why a disabled start cannot start.
    var hint: String? = nil
    /// A quieter ink for the triangles instead of the accent (the start mark beside a
    /// finished record, where it starts a new session and must not outshine the text).
    var tint: Color? = nil
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    @State private var pressed = false

    /// 28 × 36: the marks stay where they are, the target reaches most of the 52pt bar.
    static let slot = CGSize(width: 28, height: 36)

    var body: some View {
        Button(action: action) {
            mark
                .frame(width: Self.slot.width, height: Self.slot.height)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
                .modifier(ControlPressFeedback(pressed: pressed, enabled: enabled))
        }
        .buttonStyle(PressReporting(pressed: $pressed))
        .keyboardShortcut(shortcut)
        .onHover { hovering = $0 }
        .animation(LLMotion.hover(reduceMotion), value: hovering)
        .animation(LLMotion.hover(reduceMotion), value: pressed)
        .opacity(enabled ? (pressed ? 0.55 : 1) : 0.35)
        .help(help ?? glyph.accessibilityLabel)
        .accessibilityLabel(glyph.accessibilityLabel)
        .accessibilityHint(hint ?? "")
    }

    /// Ink that darkens under the pointer; the two triangles are the accent, or a `tint` that
    /// darkens the same way.
    private var color: Color {
        switch glyph {
        case .start, .play: return tint.map { hovering ? theme.ink : $0 } ?? theme.accent
        case .pause: return hovering ? theme.ink : theme.ink2
        case .stop: return hovering ? theme.ink : theme.ink3
        }
    }

    /// The triangles sit a point or two towards their point: a triangle's visual weight is at
    /// a third of its width, so centred by the box it looks left of the mark that replaces it.
    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .start:
            if tint == nil {
                PlayTriangle().fill(color).frame(width: 14, height: 16).offset(x: 2)
            } else {
                PlayTriangle().fill(color).frame(width: 10, height: 12).offset(x: 1)
            }
        case .pause:
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(color).frame(width: 2, height: 12)
                RoundedRectangle(cornerRadius: 1, style: .continuous).fill(color).frame(width: 2, height: 12)
            }
        case .play:
            PlayTriangle().fill(color).frame(width: 10, height: 12).offset(x: 1)
        case .stop:
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 10, height: 10)
        }
    }

}

/// A play mark with softened corners, so it sits with the rounded bars and square.
struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 1.2
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.maxX, y: rect.midY)
        let c = CGPoint(x: rect.minX, y: rect.maxY)
        var p = Path()
        // Walk the triangle with short arcs at each corner.
        func corner(_ from: CGPoint, _ at: CGPoint, _ to: CGPoint) {
            let v1 = CGPoint(x: from.x - at.x, y: from.y - at.y)
            let v2 = CGPoint(x: to.x - at.x, y: to.y - at.y)
            let l1 = max(hypot(v1.x, v1.y), 0.001), l2 = max(hypot(v2.x, v2.y), 0.001)
            let p1 = CGPoint(x: at.x + v1.x / l1 * r, y: at.y + v1.y / l1 * r)
            let p2 = CGPoint(x: at.x + v2.x / l2 * r, y: at.y + v2.y / l2 * r)
            if p.isEmpty { p.move(to: p1) } else { p.addLine(to: p1) }
            p.addQuadCurve(to: p2, control: at)
        }
        corner(c, a, b)
        corner(a, b, c)
        corner(b, c, a)
        p.closeSubpath()
        return p
    }
}
