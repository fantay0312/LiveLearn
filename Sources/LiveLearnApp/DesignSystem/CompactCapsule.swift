import SwiftUI

/// The single commit of a sheet or popover (round 12): 应用并重新开始, the vocabulary add /
/// import commit. It is Home's stellar capsule held still — the same almost-clear body and
/// starlit edge as 开始翻译, at 32 pt, with nothing moving — so the one action that commits
/// anything speaks the same grammar as the one on Home instead of becoming a solid ice slab.
/// Use it once per surface; every other action is a `TextButtonStyle` word or a
/// `GlyphButtonStyle` glyph.
///
/// - Dark: Home's body, `ink` at 3 % (5 % hovered, 7 % pressed) — the coolness Home's capsule
///   shows comes from its breathing glow, not its body; a 0.75 pt rim lit from above (`accent`
///   18 % on the top arc fading to 6 % at the bottom; 26 % at the top under the pointer — the
///   still capsule's own numbers, not Home's breathing rim); 22 still grains of dust in a band
///   just inside the rim, gathered round two haloed grains on the upper shoulders
///   (`CompactCapsuleGeometry`); label 13/500 in `accent`.
/// - Light (paper): forest `accent` label, a forest rim (25 % at the top, 18 % at the bottom)
///   and a forest 5 % body, and no dust — the wilds have no stars, and dots fine enough to sit
///   inside the rim print as grit on paper.
/// - Disabled: the label turns `ink3` at 60 % and the rim an even 4 % (9 % on paper); the body
///   and the dust go. Nothing to apply reads as a trace of the capsule, not as a second,
///   outlined button.
/// - Increase Contrast: Home's rule — an even 1 pt `ink` rim at 45 % (40 % of that disabled),
///   read from the theme as well as the environment, so a forced-theme render answers as the
///   window does.
/// - No clock and no live canvas: the grains are a static `Canvas`, drawn once per size.
///   Press is Home's 0.97 on the shared press curve; Reduce Motion keeps it still.
struct CompactCapsuleButtonStyle: ButtonStyle {
    static let height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration)
    }

    private struct CapsuleBody: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed && enabled
            configuration.label
                .font(LLFont.bodyStrong)
                .foregroundStyle(enabled ? theme.accent : theme.ink3.opacity(0.6))
                .lineLimit(1)
                .padding(.horizontal, 18)
                .frame(height: CompactCapsuleButtonStyle.height)
                .background {
                    Capsule().fill(fill(pressed: pressed))
                }
                .overlay {
                    Capsule().strokeBorder(rim, lineWidth: increased ? 1 : 0.75)
                }
                .overlay {
                    if enabled && theme.isDark { CapsuleGrains(tint: Color(hex: 0xD9EDF3)) }
                }
                .contentShape(Capsule())
                .contentShape(.focusEffect, Capsule())
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled, scale: 0.97))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
                .animation(LLMotion.hover(reduceMotion), value: pressed)
        }

        private var increased: Bool { theme.raisesContrast || contrast == .increased }

        private func fill(pressed: Bool) -> Color {
            guard enabled else { return .clear }
            if !theme.isDark { return theme.accent.opacity(pressed ? 0.10 : (hovering ? 0.07 : 0.05)) }
            return theme.ink.opacity(pressed ? 0.07 : (hovering ? 0.05 : 0.03))
        }

        /// Lit from above: bright on the top arc, a trace at the bottom. Disabled and Increase
        /// Contrast draw an even rim instead.
        private var rim: LinearGradient {
            if increased {
                let edge = theme.ink.opacity(0.45 * (enabled ? 1 : 0.4))
                return LinearGradient(colors: [edge, edge], startPoint: .top, endPoint: .bottom)
            }
            let color = theme.accent
            let (top, bottom): (Double, Double)
            if !enabled {
                (top, bottom) = theme.isDark ? (0.04, 0.04) : (0.09, 0.09)
            } else if theme.isDark {
                (top, bottom) = (hovering ? 0.26 : 0.18, 0.06)
            } else {
                (top, bottom) = (hovering ? 0.32 : 0.25, 0.18)
            }
            return LinearGradient(stops: [.init(color: color.opacity(top), location: 0),
                                          .init(color: color.opacity((top + bottom) / 2), location: 0.45),
                                          .init(color: color.opacity(bottom), location: 1)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The capsule's still dust: points in a thin band just inside the rim, the way Home's
/// orbiting nebula sits inside its capsule — gathered round two brighter grains on the upper
/// shoulders, a few loose along the top, a faint trace along the bottom, never over the label.
/// Positions come from `CompactCapsuleGeometry`, a pure function of the size, so every draw is
/// the same picture. Dark theme only.
private struct CapsuleGrains: View {
    let tint: Color

    var body: some View {
        Canvas { context, size in
            for grain in CompactCapsuleGeometry.grains(in: size) {
                if grain.halo {
                    context.fill(Path(ellipseIn: CGRect(x: grain.point.x - 3, y: grain.point.y - 3, width: 6, height: 6)),
                                 with: .radialGradient(Gradient(colors: [tint.opacity(grain.alpha * 0.26), .clear]),
                                                       center: grain.point, startRadius: 0, endRadius: 3))
                }
                let r = grain.radius
                context.fill(Path(ellipseIn: CGRect(x: grain.point.x - r, y: grain.point.y - r, width: r * 2, height: r * 2)),
                             with: .color(tint.opacity(grain.alpha)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the dust sits on a capsule of a given size (testable; no drawing here).
///
/// Evenly spaced grains, even jittered, read as rivets round a machined part; Home's capsule
/// reads as light because its dust clusters. So the dust is composed, not spread: two haloed
/// grains on the upper shoulders (at 14 % and 76 % of the width, the left one brighter), most
/// of the rest gathered within `clusterReach` of them along the rim, a few loose along the top
/// and a short, faint run along the bottom.
enum CompactCapsuleGeometry {
    struct Grain {
        let point: CGPoint
        let radius: CGFloat
        let alpha: Double
        let halo: Bool
    }

    static let count = 22
    /// The band the dust lives in, as depth inside the rim in points.
    static let band: ClosedRange<CGFloat> = 1.6...4.6
    /// The haloed grains: where they sit along the top (a share of the width) and how bright.
    static let anchors: [(x: CGFloat, alpha: Double)] = [(0.14, 0.70), (0.76, 0.45)]
    /// Grains gathered round each anchor, and how far along the rim they may stray from it.
    static let clustered = [7, 5]
    static let clusterReach: CGFloat = 10
    /// Faint grains along the lower half.
    static let lowerRun = 4

    static func grains(in size: CGSize) -> [Grain] {
        guard size.width > size.height, size.height > 0 else { return [] }
        let r = size.height / 2
        let straight = size.width - size.height
        let upper = CGFloat.pi * r + straight
        let perimeter = 2 * upper
        var grains: [Grain] = []
        var i = 0
        func add(_ s: CGFloat, radius: CGFloat, alpha: Double, halo: Bool = false) {
            let depth = band.lowerBound + (band.upperBound - band.lowerBound) * noise(i, 2)
            let point = place(s, depth: depth, r: r, straight: straight, width: size.width)
            grains.append(Grain(point: point, radius: radius, alpha: alpha, halo: halo))
            i += 1
        }
        for (anchor, members) in zip(anchors, clustered) {
            // Arc length of the point on the top straight under the anchor (clamped onto the
            // upper shoulders of a short capsule).
            let s = min(max(CGFloat.pi * r / 2 + anchor.x * size.width - r, CGFloat.pi * r / 4), upper - .pi * r / 4)
            add(s, radius: 0.55, alpha: anchor.alpha, halo: true)
            for _ in 0..<members {
                let a = noise(i, 1), c = noise(i, 3)
                // 0.9 of the reach along the rim, so the depth difference keeps it inside.
                let offset = (2 * a - 1) * clusterReach * 0.9
                add(min(max(s + offset, 0), upper), radius: 0.22 + 0.26 * c, alpha: 0.18 + 0.36 * c)
            }
        }
        let loose = count - anchors.count - clustered.reduce(0, +) - lowerRun
        for k in 0..<loose {
            let a = noise(i, 1), c = noise(i, 3)
            add((CGFloat(k) + 0.2 + 0.6 * a) / CGFloat(loose) * upper, radius: 0.22 + 0.2 * c, alpha: 0.12 + 0.16 * c)
        }
        for k in 0..<lowerRun {
            let a = noise(i, 1), c = noise(i, 3)
            add(upper + (CGFloat(k) + 0.2 + 0.6 * a) / CGFloat(lowerRun) * (perimeter - upper),
                radius: 0.22 + 0.2 * c, alpha: 0.05 + 0.08 * c)
        }
        return grains
    }

    /// A point `depth` inside the rim at arc length `s`, measured from the left end's mid-height
    /// clockwise over the top.
    private static func place(_ s: CGFloat, depth: CGFloat, r: CGFloat, straight: CGFloat, width: CGFloat) -> CGPoint {
        let arc = CGFloat.pi * r
        let radius = r - depth
        var s = s
        if s < arc / 2 {
            // Upper-left quarter: from mid-height (180°) to the top (270°), y down.
            let angle = CGFloat.pi + s / r
            return CGPoint(x: r + cos(angle) * radius, y: r + sin(angle) * radius)
        }
        s -= arc / 2
        if s < straight { return CGPoint(x: r + s, y: depth) }
        s -= straight
        if s < arc {
            // The right end, from the top (270°) round to the bottom (450°).
            let angle = CGFloat.pi * 1.5 + s / r
            return CGPoint(x: width - r + cos(angle) * radius, y: r + sin(angle) * radius)
        }
        s -= arc
        if s < straight { return CGPoint(x: width - r - s, y: 2 * r - depth) }
        s -= straight
        // Lower-left quarter: from the bottom (90°) back to mid-height (180°).
        let angle = CGFloat.pi / 2 + s / r
        return CGPoint(x: r + cos(angle) * radius, y: r + sin(angle) * radius)
    }

    /// A fixed value in 0..<1 per grain and channel (the shader-style sine hash), so the dust
    /// is irregular but identical on every draw.
    private static func noise(_ i: Int, _ channel: Int) -> CGFloat {
        let v = sin(Double(i) * 12.9898 + Double(channel) * 78.233) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }
}
