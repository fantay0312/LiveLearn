import SwiftUI
import ParticleMath

/// Uneven clouds share the core's silver/ice dust, with independent local drift.
struct LuminousParticleFlow: View {
    var active: Bool
    var frozenTime: Double? = nil
    var intensity: Double = 1
    var samplingStride = 1
    @Environment(\.particleInteraction) private var interaction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    /// Geometry and layout planes for the current frame, refilled in place.
    @State private var field = NebulaFieldGeometry.Field()
    @State private var layout = DustLayout()

    private static let tints: [UInt32] = [0xE3F0F6, 0x91C9D2]

    var body: some View {
        let field = self.field, layout = self.layout
        return LuminousMotion(active: active, frozenTime: frozenTime) { time in
            let now = Date.timeIntervalSinceReferenceDate
            let input = reduceMotion || staticRender || frozenTime != nil || AmbientRendering.pinnedTime != nil ? nil : interaction?.sample(at: now)
            // Nothing pushes the dust once the pointer's influence has decayed and the last
            // ripple has passed; the displacement field is then skipped for every grain.
            let pushing = input.map { $0.strength > 0.002 || !$0.pulses.isEmpty } ?? false
            Canvas { context, size in
                NebulaFieldGeometry.fill(field, time: time, sampleStride: samplingStride)
                let displace: ((Float, Float) -> (Float, Float))? = pushing ? { x, y in
                    let shift = ParticleInteraction.displacement(at: CGPoint(x: Double(x), y: Double(y)), sample: input!, time: now)
                    return (Float(shift.width), Float(shift.height))
                } : nil
                layout.layout(field, width: Float(size.width), height: Float(size.height), intensity: Float(intensity), displace: displace)
                let colors = Self.tints.map { Color(hex: $0) }
                let halos = Self.tints.map { context.resolve(ParticleSprites.halo($0)) }
                var clouds = Array(repeating: Path(), count: 16)
                let xs = layout.x, ys = layout.y, diameters = layout.diameter, alphas = layout.alpha, indices = layout.index
                for j in 0..<layout.count {
                    let index = Int(indices[j])
                    let alpha = alphas[j]
                    let diameter = CGFloat(diameters[j])
                    let x = CGFloat(xs[j]), y = CGFloat(ys[j])
                    let band = index % 4 == 0 ? 1 : 0
                    let shade = min(7, max(0, Int(alpha * 20)))
                    let rect = CGRect(x: x, y: y, width: diameter, height: diameter)
                    if diameter < 1.3 { clouds[band * 8 + shade].addRect(rect) } else { clouds[band * 8 + shade].addEllipse(in: rect) }
                    if layout.halo[j] {
                        var halo = context
                        halo.opacity = Double(alpha) * 0.17
                        halo.draw(halos[band], in: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
                    }
                }
                for index in clouds.indices where !clouds[index].isEmpty {
                    context.fill(clouds[index], with: .color(colors[index / 8].opacity(0.025 + Double(index % 8) * 0.05)))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
