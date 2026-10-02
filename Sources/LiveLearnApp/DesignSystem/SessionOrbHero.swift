import SwiftUI
import ParticleMath

/// The session's visual center stays mounted across idle, running and paused states.
///
/// Live on Home it draws with Metal (`StardustCoreMetalView`: the grains and the lit dust as
/// point sprites, the gradient under them a Canvas redrawn only when a pulse changes it); a
/// frozen frame, an offscreen render, Reduce Motion or a machine without a GPU keep the Canvas
/// `StardustOrganism`, which stays the reference. `mood` is the state the core shines in (idle,
/// running, paused); the motion eases toward it, a still frame shows it outright.
struct SessionOrbHero: View {
    let diameter: CGFloat
    var active = true
    var activationTime: Date? = nil
    var frozenTime: Double? = nil
    var activity = 0.12
    var mood = StardustMood.idle
    @State private var motion = StardustMotion()
    @State private var glow = StardustGlowState()
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.particleInteraction) private var interaction

    var body: some View {
        Group {
            if let renderer = AmbientRendering.metalRenderer(for: .metal, staticRender: staticRender, frozenTime: frozenTime, reduceMotion: reduceMotion) {
                ZStack {
                    // Paper takes no radial fill: the light theme's core is its grains alone.
                    if theme.isDark { StardustGlowGradient(pulse: glow.pulse) }
                    StardustCoreMetalView(renderer: renderer,
                                          parameters: .init(active: active, activity: activity, mood: mood, activationTime: activationTime,
                                                            palette: StardustPalette(theme: theme)),
                                          motion: motion, glow: glow)
                }
                .frame(width: diameter, height: diameter)
            } else {
                canvas
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("particle-scene")) } action: { interaction?.setHeroFrame($0) }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    private var canvas: some View {
        LuminousMotion(active: active, frozenTime: frozenTime) { time in
            let isStatic = reduceMotion || staticRender || frozenTime != nil || AmbientRendering.pinnedTime != nil
            let dynamics = isStatic ? StardustMotion.Frame(phase: time * (1 + activity * 3.2), activity: reduceMotion ? 0 : activity, mood: mood) :
                motion.sample(time: time, targetActivity: activity, targetMood: mood)
            let input = isStatic ? nil : interaction?.sample()
            let frame = interaction?.heroFrame ?? .zero
            let point = input.map { CGPoint(x: ($0.point.x - frame.minX) / max(1, frame.width),
                                            y: ($0.point.y - frame.minY) / max(1, frame.height)) }
            let distance = point.map { hypot($0.x - 0.5, $0.y - 0.5) } ?? 10
            let strength = (input?.strength ?? 0) * max(0, 1 - distance / 1.2)
            let now = Date.timeIntervalSinceReferenceDate
            let click = input?.pulses.filter { frame.insetBy(dx: -30, dy: -30).contains($0.point) }.last?.time
            let pulseTime = [activationTime?.timeIntervalSinceReferenceDate, click].compactMap { $0 }.max()
            let age = pulseTime.map { now - $0 } ?? 10
            let pulse = isStatic || age < 0 || age > 0.9 ? 0 : sin(age / 0.9 * .pi) * exp(-age * 1.6)
            StardustOrganism(time: dynamics.phase, pointer: point, influence: strength * (input?.dragging == true ? 1 : 0.7),
                             pulse: pulse, activity: dynamics.activity, mood: dynamics.mood)
                .frame(width: diameter, height: diameter)
        }
    }
}
