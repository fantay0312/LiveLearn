import AppKit
import Metal
import SwiftUI
import ParticleMath

/// The Home sky: the drifting stars of `StellarAtmosphere` and, on Home, the dust clouds of
/// `LuminousParticleFlow` over them. With `renderer == .metal` one Metal layer draws both while
/// the surface is live (one full-window drawable set instead of two, one draw call); a static
/// render, Reduce Motion, a machine without a GPU or a caller on `.canvas` gets the two Canvas
/// views, mounted exactly as before.
struct AmbientSky: View {
    var immersive: Bool
    var starsActive: Bool
    /// The dust layer's intensity, or nil when the dust is not mounted (every page but Home).
    var dustIntensity: Double?
    /// Off immersive Home: the page's rails and top line, which the stars keep off.
    var keepOut = SkyKeepOut()
    var renderer: AmbientRenderer = .canvas
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let metal = AmbientRendering.metalRenderer(for: renderer, layer: .sky, staticRender: staticRender, frozenTime: nil, reduceMotion: reduceMotion) {
            AmbientSkyMetalView(renderer: metal, stars: .init(immersive: immersive, active: starsActive, keepOut: keepOut),
                                dust: dustIntensity.map { .init(active: true, intensity: $0, sampleStride: 1) })
                .allowsHitTesting(false).accessibilityHidden(true)
        } else {
            StellarAtmosphere(immersive: immersive, active: starsActive, keepOut: keepOut)
            if let dustIntensity { LuminousParticleFlow(active: true, intensity: dustIntensity) }
        }
    }
}

/// The Metal sky layer: stars, dust, or both, each with its own clock.
struct AmbientSkyMetalView: NSViewRepresentable {
    struct Stars: Equatable {
        var immersive: Bool
        var active: Bool
        var keepOut = SkyKeepOut()
    }

    struct Dust: Equatable {
        var active: Bool
        var intensity: Double
        var sampleStride: Int
    }

    let renderer: ParticleMetalRenderer
    var stars: Stars?
    var dust: Dust?

    func makeNSView(context: Context) -> AmbientSkyHostView {
        let view = AmbientSkyHostView(renderer: renderer)
        apply(to: view, context)
        return view
    }

    func updateNSView(_ view: AmbientSkyHostView, context: Context) {
        apply(to: view, context)
    }

    static func dismantleNSView(_ view: AmbientSkyHostView, coordinator: ()) {
        view.detach()
    }

    private func apply(to view: AmbientSkyHostView, _ context: Context) {
        view.interaction = context.environment.particleInteraction
        view.ambientPaused = context.environment.ambientMotionPaused
        view.reduceMotion = context.environment.accessibilityReduceMotion
        view.set(stars: stars, dust: dust)
    }
}

/// Builds the sky's point buffer for one frame — the stars at their time, the dust at its own,
/// each the sprites its Canvas would fill. Owned by the host view; the offscreen parity render
/// builds the same frame without a window.
@MainActor
final class AmbientSkyFrame {
    private let field = NebulaFieldGeometry.Field()
    private let layout = DustLayout()
    let capacity = StarFieldGeometry.pointCapacity() + DustLayout.pointCapacity()

    /// Star pearl / ice (`StellarAtmosphere`), then dust pearl / ice (`LuminousParticleFlow`).
    static let palette = [0xECEFF4, 0xB7D3F6, 0xE3F0F6, 0x91C9D2].map { AmbientRendering.components(hex: UInt32($0)) }

    /// `input` is the pointer sample pushing the dust (nil: nothing pushes) taken at `inputTime`;
    /// `width` × `height` is the layer in points, `scale` its backing scale.
    func encode(into buffer: MTLBuffer, stars: AmbientSkyMetalView.Stars?, starTime: Double,
                dust: AmbientSkyMetalView.Dust?, dustTime: Double, input: ParticleInteraction.Sample?, inputTime: Double,
                width: Double, height: Double, scale: Float) -> ParticleFrame {
        let out = buffer.contents().bindMemory(to: ParticlePoint.self, capacity: capacity)
        var count = 0
        if let stars {
            count += StarFieldGeometry.encodePoints(into: out, capacity: capacity, count: stars.immersive ? 290 : 85,
                                                    time: starTime, width: width, height: height,
                                                    immersive: stars.immersive, keepOut: stars.keepOut, scale: scale, colorBase: 0)
        }
        if let dust {
            // Nothing pushes the dust once the pointer's influence has decayed and the last
            // ripple has passed; the displacement field is then skipped for every grain. A
            // pointer that merely *rests* inside the window keeps pushing, though — `move(to:)`
            // drives the strength to 1 and only `leave()` decays it — so the common idle case
            // is "pushing, from one fixed place". Bound it: the pointer's Gaussian moves a grain
            // by less than a thousandth of a point past 330 pt, and a click ring never reaches
            // further than 390 pt from where it started, so every grain outside that box takes
            // the same (0, 0) the function would compute for it, without the call.
            let pushing = input.map { $0.strength > 0.002 || !$0.pulses.isEmpty } ?? false
            NebulaFieldGeometry.fill(field, time: dustTime, sampleStride: dust.sampleStride)
            var displace: ((Float, Float) -> (Float, Float))?
            if pushing, let sample = input {
                var lo = SIMD2<Float>(.infinity, .infinity), hi = SIMD2<Float>(-.infinity, -.infinity)
                if sample.strength > 0 {
                    lo = SIMD2(Float(sample.point.x) - 330, Float(sample.point.y) - 330)
                    hi = SIMD2(Float(sample.point.x) + 330, Float(sample.point.y) + 330)
                }
                for pulse in sample.pulses {
                    lo = SIMD2(min(lo.x, Float(pulse.point.x) - 390), min(lo.y, Float(pulse.point.y) - 390))
                    hi = SIMD2(max(hi.x, Float(pulse.point.x) + 390), max(hi.y, Float(pulse.point.y) + 390))
                }
                displace = { x, y in
                    guard x > lo.x, x < hi.x, y > lo.y, y < hi.y else { return (0, 0) }
                    let shift = ParticleInteraction.displacement(at: CGPoint(x: Double(x), y: Double(y)), sample: sample, time: inputTime)
                    return (Float(shift.width), Float(shift.height))
                }
            }
            layout.layout(field, width: Float(width), height: Float(height), intensity: Float(dust.intensity), displace: displace)
            count += layout.encodePoints(into: out + count, capacity: capacity - count, scale: scale, colorBase: 2)
        }
        return ParticleFrame(vertices: buffer, points: 0..<count, palette: Self.palette, glow: nil)
    }
}

@MainActor
final class AmbientSkyHostView: ParticleMetalHostView {
    var interaction: ParticleInteraction?
    private var stars: AmbientSkyMetalView.Stars?
    private var dust: AmbientSkyMetalView.Dust?
    private var starClock = AmbientClock()
    private var dustClock = AmbientClock()
    private let scene = AmbientSkyFrame()
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0

    override init(renderer: ParticleMetalRenderer) {
        buffers = renderer.makeVertexBuffers(capacity: StarFieldGeometry.pointCapacity() + DustLayout.pointCapacity(), label: "sky")
        super.init(renderer: renderer)
    }

    func set(stars: AmbientSkyMetalView.Stars?, dust: AmbientSkyMetalView.Dust?) {
        guard stars != self.stars || dust != self.dust else { return }
        // The dust view is unmounted off Home and starts again from zero when it comes back.
        if dust == nil, self.dust != nil { dustClock = AmbientClock() }
        self.stars = stars
        self.dust = dust
        refreshPlaying()
        requestFrame()
    }

    override func applyGate(_ open: Bool) -> Bool {
        starClock.set(playing: open && (stars?.active ?? false))
        dustClock.set(playing: open && (dust?.active ?? false))
        return starClock.playing || dustClock.playing
    }

    override func render(at now: Date) {
        guard !buffers.isEmpty else { return }
        // The ring advances only for a frame the GPU took: a skipped frame (drawable or slot
        // unavailable) reuses this buffer next time, so the buffer being written is never one
        // of the ≤ `framesInFlight` still being read.
        let buffer = buffers[bufferIndex]
        let reference = Date.timeIntervalSinceReferenceDate
        // A pinned clock is a capture: the pointer stays out of it, as in the Canvas path.
        let input = dust != nil && AmbientRendering.pinnedTime == nil ? interaction?.sample(at: reference) : nil
        let encoded = scene.encode(into: buffer, stars: stars, starTime: starClock.time(at: now),
                                   dust: dust, dustTime: dustClock.time(at: now), input: input, inputTime: reference,
                                   width: Double(bounds.width), height: Double(bounds.height), scale: Float(metalLayer.contentsScale))
        if renderer.draw(encoded, into: metalLayer, inFlight: inFlight) {
            bufferIndex = (bufferIndex + 1) % buffers.count
        }
    }
}
