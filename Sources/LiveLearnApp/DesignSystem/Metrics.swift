import SwiftUI

/// Design language §5.
enum LLMetrics {
    static func space(_ n: Int) -> CGFloat {
        switch n {
        case 1: return 4
        case 2: return 8
        case 3: return 12
        case 4: return 16
        case 5: return 24
        case 6: return 32
        case 7: return 48
        default: return 64
        }
    }

    enum Radius {
        static let control: CGFloat = 6
        static let card: CGFloat = 10
        static let overlay: CGFloat = 14
    }

    static let gutterWidth: CGFloat = 72
    static let measure: CGFloat = 640
    static let trafficLightInset: CGFloat = 78
    static let controlHeight: CGFloat = 28
    static let defaultWindow = CGSize(width: 1180, height: 760)
    static let minWindow = CGSize(width: 960, height: 600)
    static let overlayMaxWidth: CGFloat = 880
    static let overlayScreenMargin: CGFloat = 80
    static let overlayBottomOffset: CGFloat = 64
    static let menuWidth: CGFloat = 280
}

struct Hairline: View {
    @Environment(\.theme) private var theme
    var axis: Axis = .horizontal
    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

extension View {
    /// Quiet card: a themed surface lying on the ground. No
    /// shadow; the slight tone difference is the whole edge. `bordered` adds a hairline for
    /// the rare card that must hold its shape against a same-toned background.
    func llCard(bordered: Bool = false) -> some View {
        modifier(CardModifier(bordered: bordered))
    }

    /// The one material for anything that floats above the page (round 12): the paper menu's
    /// sheet, and any sheet a surface lifts over its content.
    ///
    /// - Dark: `surface` with a 0.5 pt edge lit from above (`LLTheme.floatingEdge`) and no
    ///   shadow. A drop shadow is invisible on the black ground, and a same-strength ring on all
    ///   four sides read as a pasted-on graphite box; light from one side reads as a lit object
    ///   in the sky.
    /// - Light: `surface` paper, a 0.5 pt `hairline` edge, and one soft shadow (black 14 %,
    ///   radius 14, y 6) cast by the shape alone. Shadowing the composite made every glyph and
    ///   mark on the paper cast its own halo, which smudged the sheet.
    /// - Increase Contrast: an even `hairline` edge in both themes (the lifted token).
    func floatingPaper(cornerRadius: CGFloat = LLMetrics.Radius.card) -> some View {
        modifier(FloatingPaperModifier(radius: cornerRadius))
    }
}

extension LLTheme {
    /// The edge of the floating material (`floatingPaper`, the settings card): in the dark, `ink`
    /// lit from above — 16 % along the top, 7 % a third of the way down, 3 % at the bottom; on
    /// paper and under Increase Contrast the even `hairline`. One recipe, so every floating
    /// thing is lit by the same sky; the caller picks the line width. A shape style rather than
    /// a branch, so a theme switch keeps the stroked view's identity.
    func floatingEdge(contrast: ColorSchemeContrast) -> AnyShapeStyle {
        guard isDark && contrast != .increased else { return AnyShapeStyle(hairline) }
        return AnyShapeStyle(LinearGradient(stops: [.init(color: ink.opacity(0.16), location: 0),
                                                    .init(color: ink.opacity(0.07), location: 0.35),
                                                    .init(color: ink.opacity(0.03), location: 1)],
                                            startPoint: .top, endPoint: .bottom))
    }
}

private struct FloatingPaperModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if theme.isDark {
                    shape.fill(theme.surface)
                } else {
                    shape.fill(theme.surface).shadow(color: .black.opacity(0.14), radius: 14, y: 6)
                }
            }
            .overlay {
                shape.strokeBorder(theme.floatingEdge(contrast: contrast), lineWidth: 0.5).allowsHitTesting(false)
            }
    }
}

private struct CardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let bordered: Bool
    func body(content: Content) -> some View {
        content
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                    .strokeBorder(theme.hairline.opacity(bordered ? 1 : 0.55), lineWidth: 1)
            }
    }
}
