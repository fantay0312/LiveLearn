import SwiftUI

/// The row of the one orbit of the app — "where you are": three cells over one
/// `NavigationStarField`, in the dock and in Home's modes. Its geometry lives here once; the two
/// rows (`OrbitRowStack`), the orbit's centres and text mask (`NavigationStarMotion`), the
/// routes' width cap and the parity render all read it, so the two orbits share their grains,
/// density and flights by construction.
enum OrbitRow {
    static let cells = 3
    static let cell = CGSize(width: 64, height: 36)
    static let spacing: CGFloat = 24
    /// Around the cells: 12 pt at the sides, 4 pt above and below.
    static let inset = CGSize(width: 12, height: 4)
    /// 3 × 64 + 2 × 24 + 2 × 12 = 264 by 36 + 2 × 4 = 44.
    static let size = CGSize(width: CGFloat(cells) * cell.width + CGFloat(cells - 1) * spacing + 2 * inset.width,
                             height: cell.height + 2 * inset.height)

    /// The centre of cell `index` from the row's leading edge (44 / 132 / 220).
    static func centre(_ index: Int) -> CGFloat {
        inset.width + cell.width / 2 + CGFloat(min(cells - 1, max(0, index))) * (cell.width + spacing)
    }
}

/// Cells laid on `OrbitRow`: each cell frames itself at `OrbitRow.cell`.
struct OrbitRowStack<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: OrbitRow.spacing) { content() }
            .padding(.horizontal, OrbitRow.inset.width)
            .padding(.vertical, OrbitRow.inset.height)
    }
}

/// Interleaved silver dust wraps the selected destination without covering its label.
///
/// Live it draws with Metal (`NavigationStarScene` over the same `NavigationStarMotion`, its own
/// display link, no SwiftUI render pass); a static render, a frozen time, Reduce Motion, a
/// machine without a GPU or a caller on `.canvas` gets the Canvas, which stays the reference.
/// `layer` names the field for `--ambient-layers` (`.nav` in the dock, `.nebula` on Home);
/// `active` stops its clock while the surface is hidden (Home's modes off Home), holding the
/// last frame as a stopped Canvas would. `strength` scales every grain's alpha and nothing
/// else: Home's modes draw the dock's orbit a step quieter (`modeStrength`), so the page
/// location outranks a choice within the page.
struct NavigationStarField: View {
    static let modeStrength = 0.8
    let selection: Int
    var active = true
    var frozenTime: Double? = nil
    var renderer: AmbientRenderer = .canvas
    var layer: AmbientLayer = .nav
    var strength = 1.0
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = NavigationStarMotion()
    @State private var canvasRate = NavigationStarMotion.idleRate

    var body: some View {
        Group {
            if let metal = AmbientRendering.metalRenderer(for: renderer, layer: layer, staticRender: staticRender, frozenTime: frozenTime, reduceMotion: reduceMotion) {
                SpriteLayerView(renderer: metal, scene: NavigationStarScene(
                    motion: motion, selection: selection,
                    tint: theme.isDark ? AmbientRendering.components(hex: 0xD8E9F2) : AmbientRendering.components(theme.accent),
                    halos: theme.isDark, active: active, strength: strength))
            } else {
                LuminousMotion(active: active, frozenTime: frozenTime, rate: canvasRate) { time in
                    let points = motion.sample(time: time, selection: selection,
                                               stationary: staticRender || reduceMotion || frozenTime != nil)
                    NavigationStarCanvas(points: points, time: reduceMotion ? 0 : time, strength: strength)
                        .onChange(of: motion.preferredRate(selection: selection), initial: true) { _, rate in
                            canvasRate = rate
                        }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// On paper the grains are crisp ink dots without their feathered halos: a soft light on cream
/// reads as a smudge, not a glow (`NavigationStarScene` follows the same rule).
struct NavigationStarCanvas: View {
    let points: [CGPoint]
    let time: Double
    var strength = 1.0
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            let color = theme.isDark ? Color(hex: 0xD8E9F2) : theme.accent
            for (index, point) in points.enumerated() {
                let x = point.x * size.width, y = point.y * size.height
                let grain = NavigationStarMotion.appearance(index, time: time)
                let visibility = NavigationStarMotion.textVisibility(at: point)
                let radius = grain.radius, haloRadius = grain.haloRadius
                if theme.isDark {
                    context.fill(Path(ellipseIn: CGRect(x: x - haloRadius, y: y - haloRadius,
                                                        width: haloRadius * 2, height: haloRadius * 2)),
                                 with: .radialGradient(Gradient(colors: [color.opacity(grain.haloOpacity * visibility * strength), .clear]),
                                                       center: CGPoint(x: x, y: y), startRadius: 0, endRadius: haloRadius))
                }
                context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(grain.opacity * visibility * strength)))
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
