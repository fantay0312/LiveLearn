import SwiftUI
import ParticleMath

/// Independently drifting point sources share the scene's visibility-aware clock.
struct StellarAtmosphere: View {
    var immersive = false
    var active = false
    /// Off immersive Home: the page's rails and top line, which the stars keep off.
    var keepOut = SkyKeepOut()

    /// Where star `index` is at `time`; anchors and phases come from a table built once.
    static func position(index: Int, time: Double, size: CGSize) -> CGPoint {
        StarFieldGeometry.position(index: index, time: time, size: size)
    }

    private static let pearl = Color(hex: 0xECEFF4)
    private static let ice = Color(hex: 0xB7D3F6)

    var body: some View {
        LuminousMotion(active: active) { time in
        Canvas { context, size in
            let count = immersive ? 290 : 85
            let halos = [context.resolve(ParticleSprites.halo(0xECEFF4)), context.resolve(ParticleSprites.halo(0xB7D3F6))]
            // Idle Home leaves its operating area dark and keeps glints off its words; the
            // composition is the page's own (`HomeComposition`), so the quiet follows the controls.
            let composition = immersive ? HomeComposition(windowWidth: size.width, windowHeight: size.height) : nil
            for index in 0..<count {
                let star = StarFieldGeometry.stars[index]
                let position = StarFieldGeometry.position(index: index, time: time, size: size)
                let x = position.x, y = position.y
                let look = StarFieldGeometry.look(star, index: index, at: position, time: time, composition: composition, keepOut: keepOut)
                let tint = star.ice ? Self.ice : Self.pearl
                if let glint = look.glint {
                    var halo = context
                    halo.opacity = glint.halo
                    halo.draw(halos[star.ice ? 1 : 0], in: CGRect(x: x - 6, y: y - 6, width: 12, height: 12))
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - 3.5, y: y)); cross.addLine(to: CGPoint(x: x + 3.5, y: y))
                    cross.move(to: CGPoint(x: x, y: y - 3.5)); cross.addLine(to: CGPoint(x: x, y: y + 3.5))
                    context.stroke(cross, with: .color(tint.opacity(glint.cross)), lineWidth: 0.5)
                }
                let diameter = look.diameter
                context.fill(Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2,
                                                    width: diameter, height: diameter)), with: .color(tint.opacity(look.opacity)))
            }
        }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
