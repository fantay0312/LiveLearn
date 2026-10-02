import SwiftUI
import ParticleMath

/// The tints of the core for a theme, the one source both paths read (the Metal core resolves
/// it when its parameters change, this Canvas each frame), so they cannot drift apart: the lit
/// current, the front and the far grains, each at rest and at the paused silver, and the peak
/// alpha of the blurred lit dust.
///
/// Dark: pearl / ice / far ice, going to neutral silver when paused. Light follows the paper
/// rule — grains are ink on paper, never light: the lit current alone is forest (`accent`), the
/// front and far body are both full ink (depth on paper is size and alpha, not a paler ink,
/// which read as a washed-out ball), a paused core keeps only a faded forest current (halfway
/// to `ink2`: all the way, antialiased onto cream, it read as grey soot), and there is no lit
/// dust at all (a blurred halo on paper reads as a stain, not a glow). Ink on paper has no glow
/// to carry the current, so there the current and the front stand forward by alpha instead
/// (`toneGain`): the focal mass the light gives on the sky.
struct StardustPalette: Equatable {
    var tones: [SIMD4<Float>]
    var silver: [SIMD4<Float>]
    var litAlpha: Float
    /// Each tone's alpha gain over its bins (current, front, far), capped at 1 per grain.
    var toneGain: SIMD3<Float>

    init(theme: LLTheme) {
        if theme.isDark {
            tones = [0xE3F0F6, 0x91C9D2, 0x7998B3].map { AmbientRendering.components(hex: $0) }
            silver = [0xE5E8EC, 0xA7B0B9, 0x858F9B].map { AmbientRendering.components(hex: $0) }
            litAlpha = 0.16
            toneGain = SIMD3(1, 1, 1)
        } else {
            let accent = AmbientRendering.components(theme.accent), ink = AmbientRendering.components(theme.ink)
            let ink2 = AmbientRendering.components(theme.ink2)
            tones = [accent, ink, ink]
            silver = [accent + (ink2 - accent) * 0.5, ink, ink]
            litAlpha = 0
            toneGain = SIMD3(1.2, 1.3, 1)
        }
    }

    /// Pearl (the lit current), ice (front) and far, `amount` of the way to silver.
    func tints(silver amount: Double) -> [SIMD4<Float>] {
        let k = Float(min(1, max(0, amount)))
        return zip(tones, silver).map { $0 + ($1 - $0) * k }
    }

    /// The lit dust's peak alpha: a paused core's current glows at 80 %.
    func lit(silver amount: Double) -> Float { litAlpha * (1 - 0.2 * Float(min(1, max(0, amount)))) }

    func colors(silver amount: Double) -> [Color] {
        tints(silver: amount).map { Color(.sRGB, red: Double($0.x), green: Double($0.y), blue: Double($0.z)) }
    }
}

struct StardustOrganism: View {
    let time: Double
    var pointer: CGPoint? = nil
    var influence = 0.0
    var pulse = 0.0
    var miniature = false
    var activity = 0.0
    var mood = StardustMood.idle
    @Environment(\.theme) private var theme
    /// The grains of the current frame, refilled in place: a frame allocates no geometry.
    @State private var workspace = StardustGeometry.Workspace()

    /// The faint depth inside the cloud, drawn before the grains: a small ice-tinted pool at the
    /// centre that a pulse lifts, not a haze — the cloud's light comes from its grains, and the
    /// surrounding sky stays black. Dark only (paper takes no radial fill). Shared with the Metal
    /// core, which draws this same gradient in a Canvas under its grains, so the two paths
    /// cannot drift apart.
    static func fillGlow(_ context: GraphicsContext, size: CGSize, theme: LLTheme, pulse: Double) {
        guard theme.isDark else { return }
        let side = min(size.width, size.height)
        let center = CGPoint(x: side * StardustGeometry.center.x, y: side * StardustGeometry.center.y)
        context.fill(Path(ellipseIn: CGRect(x: center.x - side * 0.30, y: center.y - side * 0.30, width: side * 0.60, height: side * 0.60)),
            with: .radialGradient(Gradient(stops: [
                .init(color: Color(hex: 0xDFE8F7).opacity(0.026 + pulse * 0.05), location: 0),
                .init(color: Color(hex: 0x91C9D2).opacity(0.010), location: 0.45),
                .init(color: .clear, location: 1)
            ]), center: center, startRadius: 0, endRadius: side * 0.30))
    }

    var body: some View {
        let workspace = self.workspace
        return Canvas { context, size in
            let side = min(size.width, size.height)
            let palette = StardustPalette(theme: theme)
            let colors = palette.colors(silver: mood.silver)
            let litAlpha = Double(palette.lit(silver: mood.silver))
            Self.fillGlow(context, size: size, theme: theme, pulse: pulse)

            StardustGeometry.fill(workspace, time: time, pointer: pointer, influence: influence, pulse: pulse,
                                  sampleStride: miniature ? 9 : 1, activity: activity, mood: mood)
            var batches = Array(repeating: Path(), count: 24)
            var litDust = Path()
            let xs = workspace.x, ys = workspace.y, radii = workspace.radius, alphas = workspace.opacity, tones = workspace.tone
            for j in 0..<workspace.count {
                let radius = miniature ? max(0.28, side * CGFloat(radii[j]) * 2.5) : side * CGFloat(radii[j])
                let rect = CGRect(x: CGFloat(xs[j]) * side - radius, y: CGFloat(ys[j]) * side - radius,
                                  width: radius * 2, height: radius * 2)
                let alpha = alphas[j]
                let bin = Int(tones[j]) * 8 + min(7, max(0, Int(alpha * 8)))
                // A grain narrower than 1.3pt is a soft dot either way once antialiased; a rect is
                // four straight segments where an ellipse is four curves to flatten.
                if radius < 0.65 { batches[bin].addRect(rect) } else { batches[bin].addEllipse(in: rect) }
                if alpha > 0.60 && litAlpha > 0 {
                    litDust.addRect(rect.insetBy(dx: -radius * 1.8, dy: -radius * 1.8))
                }
            }
            if litAlpha > 0 {
                var glow = context
                glow.addFilter(.blur(radius: side * 0.005))
                glow.fill(litDust, with: .color(colors[1].opacity(litAlpha)))
            }
            for index in batches.indices where !batches[index].isEmpty {
                let alpha = min(1, Float((Double(index % 8) + 0.5) / 8) * palette.toneGain[index / 8])
                context.fill(batches[index], with: .color(colors[index / 8].opacity(Double(alpha))))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
