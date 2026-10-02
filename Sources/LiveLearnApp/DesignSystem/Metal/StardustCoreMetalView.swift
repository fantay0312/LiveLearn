import AppKit
import Metal
import Observation
import SwiftUI
import ParticleMath

/// The one value the Metal core hands back to SwiftUI: the pulse that also lifts the gradient
/// under it. Written only when it changes, so an idle core never invalidates a view.
@MainActor @Observable
final class StardustGlowState {
    var pulse = 0.0
}

/// The soft light inside the cloud, drawn under the Metal grains by the same Canvas code the
/// Canvas path uses (`StardustOrganism.fillGlow`), so the gradient is identical by construction.
struct StardustGlowGradient: View {
    var pulse: Double
    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { context, size in
            StardustOrganism.fillGlow(context, size: size, theme: theme, pulse: pulse)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The Metal core: the lit-dust glow and the 6,400 grains of `StardustOrganism`, with the
/// pointer pull, click pulses and activity / mood integration of `SessionOrbHero`.
struct StardustCoreMetalView: NSViewRepresentable {
    struct Parameters: Equatable {
        var active: Bool
        var activity: Double
        /// The target mood; the motion eases the drawn one toward it.
        var mood: StardustMood
        var activationTime: Date?
        var palette: StardustPalette
    }

    let renderer: ParticleMetalRenderer
    var parameters: Parameters
    let motion: StardustMotion
    let glow: StardustGlowState

    func makeNSView(context: Context) -> StardustCoreHostView {
        let view = StardustCoreHostView(renderer: renderer, motion: motion, glow: glow)
        apply(to: view, context)
        return view
    }

    func updateNSView(_ view: StardustCoreHostView, context: Context) {
        apply(to: view, context)
    }

    static func dismantleNSView(_ view: StardustCoreHostView, coordinator: ()) {
        view.detach()
    }

    private func apply(to view: StardustCoreHostView, _ context: Context) {
        view.interaction = context.environment.particleInteraction
        view.ambientPaused = context.environment.ambientMotionPaused
        view.reduceMotion = context.environment.accessibilityReduceMotion
        view.set(parameters)
    }
}

/// Builds the core's point buffer for one frame — the lit-dust boxes for the glow, then the
/// grains — with the glow's blur targets sized to the layer. Owned by the host view; the
/// offscreen parity render builds the same frame without a window.
@MainActor
final class StardustCoreFrame {
    private let workspace = StardustGeometry.Workspace()
    let capacity = StardustGeometry.Workspace.pointCapacity()
    private var glowTextures: GlowTextures?

    /// The layer was resized: the blur targets are stale.
    func invalidateTextures() { glowTextures = nil }

    /// `phase` is the integrated stardust phase (`StardustMotion.Frame.phase`), `mood` the eased
    /// mood of the same frame, `pointer` in unit space; `side` is the stage side in points,
    /// `width` × `height` the target in pixels.
    func encode(into buffer: MTLBuffer, renderer: ParticleMetalRenderer, phase: Double, activity: Double, mood: StardustMood,
                pointer: CGPoint?, influence: Double, pulse: Double, palette: StardustPalette,
                side: Double, scale: Float, width: Int, height: Int) -> ParticleFrame {
        StardustGeometry.fill(workspace, time: phase, pointer: pointer, influence: influence, pulse: pulse,
                              activity: activity, mood: mood)
        let out = buffer.contents().bindMemory(to: ParticlePoint.self, capacity: capacity)
        let (lit, grains) = workspace.encodePoints(into: out, capacity: capacity, side: side, scale: scale, toneGain: palette.toneGain)
        let tints = palette.tints(silver: mood.silver)
        let litAlpha = palette.lit(silver: mood.silver)
        // No lit dust (the light theme): the boxes stay in the buffer, but no glow pass runs.
        var glow: ParticleFrame.Glow?
        if litAlpha > 0 {
            if glowTextures == nil || glowTextures?.width != width || glowTextures?.height != height {
                glowTextures = renderer.makeGlowTextures(width: width, height: height)
            }
            glow = glowTextures.map {
                ParticleFrame.Glow(lit: 0..<lit, sigma: Float(side * 0.005) * scale,
                                   tint: SIMD4(tints[1].x, tints[1].y, tints[1].z, litAlpha), textures: $0)
            }
        }
        return ParticleFrame(vertices: buffer, points: lit..<(lit + grains), palette: tints, glow: glow)
    }
}

@MainActor
final class StardustCoreHostView: ParticleMetalHostView {
    var interaction: ParticleInteraction?
    private let motion: StardustMotion
    private let glow: StardustGlowState
    private var parameters: StardustCoreMetalView.Parameters?
    private var clock = AmbientClock()
    private let scene = StardustCoreFrame()
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0

    init(renderer: ParticleMetalRenderer, motion: StardustMotion, glow: StardustGlowState) {
        self.motion = motion
        self.glow = glow
        buffers = renderer.makeVertexBuffers(capacity: StardustGeometry.Workspace.pointCapacity(), label: "core")
        super.init(renderer: renderer)
    }

    func set(_ parameters: StardustCoreMetalView.Parameters) {
        guard parameters != self.parameters else { return }
        self.parameters = parameters
        refreshPlaying()
        requestFrame()
    }

    override func applyGate(_ open: Bool) -> Bool {
        clock.set(playing: open && (parameters?.active ?? false))
        return clock.playing
    }

    override func drawableSizeDidChange() {
        scene.invalidateTextures()
    }

    override func render(at now: Date) {
        guard let parameters, !buffers.isEmpty else { return }
        let time = clock.time(at: now)
        // The same frame as `SessionOrbHero` computes for the Canvas; a pinned clock is a
        // capture and takes its static form (no integration, no pointer, no pulse).
        let pinned = AmbientRendering.pinnedTime != nil
        let dynamics = pinned ? StardustMotion.Frame(phase: time * (1 + parameters.activity * 3.2), activity: parameters.activity, mood: parameters.mood)
            : motion.sample(time: time, targetActivity: parameters.activity, targetMood: parameters.mood)
        let input = pinned ? nil : interaction?.sample()
        let hero = interaction?.heroFrame ?? .zero
        let point = input.map { CGPoint(x: ($0.point.x - hero.minX) / max(1, hero.width),
                                        y: ($0.point.y - hero.minY) / max(1, hero.height)) }
        let distance = point.map { hypot($0.x - 0.5, $0.y - 0.5) } ?? 10
        let strength = (input?.strength ?? 0) * max(0, 1 - distance / 1.2)
        let reference = Date.timeIntervalSinceReferenceDate
        let click = input?.pulses.filter { hero.insetBy(dx: -30, dy: -30).contains($0.point) }.last?.time
        let pulseTime = [parameters.activationTime?.timeIntervalSinceReferenceDate, click].compactMap { $0 }.max()
        let age = pulseTime.map { reference - $0 } ?? 10
        let pulse = pinned || age < 0 || age > 0.9 ? 0 : sin(age / 0.9 * .pi) * exp(-age * 1.6)
        if glow.pulse != pulse { glow.pulse = pulse }

        // See `AmbientSkyHostView.render`: the ring advances only for a committed frame.
        let buffer = buffers[bufferIndex]
        let size = metalLayer.drawableSize
        let encoded = scene.encode(into: buffer, renderer: renderer, phase: dynamics.phase, activity: dynamics.activity,
                                   mood: dynamics.mood, pointer: point, influence: strength * (input?.dragging == true ? 1 : 0.7), pulse: pulse,
                                   palette: parameters.palette, side: Double(min(bounds.width, bounds.height)),
                                   scale: Float(metalLayer.contentsScale), width: Int(size.width), height: Int(size.height))
        if renderer.draw(encoded, into: metalLayer, inFlight: inFlight) {
            bufferIndex = (bufferIndex + 1) % buffers.count
        }
    }
}
