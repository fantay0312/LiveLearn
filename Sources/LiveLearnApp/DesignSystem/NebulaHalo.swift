import SwiftUI

/// A broken cloud of orbiting light around the action capsule. Uneven depth and phases prevent
/// a dotted loading ring. On paper the grains are crisp ink dots without their soft halos
/// (`NebulaHaloScene` follows the same rule).
struct NebulaHalo: View {
    let time: Double
    var strength = 1.0
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            let color = theme.isDark ? Color(hex: 0xD9EDF3) : theme.accent
            let halo = context.resolve(ParticleSprites.halo(theme.isDark ? 0xD9EDF3 : theme.accentHex))
            var dust = Array(repeating: Path(), count: 6)
            for index in 0..<72 {
                let seed = Double((index * 37 + 11) % 73) / 73
                let depth = Double((index * 19 + 7) % 71) / 71
                let a = Double(index) * 2.39996 + time * (0.33 + depth * 0.17)
                let radial = 0.80 + depth * 0.20 + sin(time * 0.55 + seed * 12) * 0.045
                let x = size.width * (0.5 + cos(a) * 0.46 * radial)
                let y = size.height * (0.5 + sin(a) * 0.40 * radial)
                let wave = 0.5 + 0.5 * sin(a * 2 - time * 0.21)
                let flow = 0.30 + 0.70 * wave * wave
                let alpha = (0.22 + depth * 0.60) * flow * strength
                let radius = 0.28 + seed * 0.48
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                dust[min(5, max(0, Int(alpha * 6)))].addEllipse(in: rect)
                if theme.isDark && seed > 0.94 {
                    var glow = context
                    glow.opacity = alpha * 0.26
                    glow.draw(halo, in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
                }
            }
            for index in dust.indices where !dust[index].isEmpty {
                context.fill(dust[index], with: .color(color.opacity((Double(index) + 0.5) / 6)))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
