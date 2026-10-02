import CoreGraphics
import Foundation
import simd
import ParticleMath

// The four small Home surfaces as sprite scenes. Each mirrors its Canvas constant for constant
// and in the Canvas's fill order; the Canvas code stays in its view as the reference.
//
// Every encoder writes into a `Workspace` its host allocated once, so none of them touches the
// heap per frame.

/// `ParticleWordmark`'s grains: the glyph-sampled rects breathing in five alpha bins, with a halo
/// on every 157th grain. Halos come first (drawn inline in the Canvas loop), then the bins from
/// faint to bright.
struct WordmarkScene: SpriteScene {
    /// The grain tint: `ParticleWordmark.tint` (dark `#E3F0F6`, light `theme.ink`).
    var tint: SIMD4<Float>
    /// True on paper, where the word is crisp ink without soft points, at the engraved alphas
    /// (`ParticleWordmark.alpha`).
    var engraved = false
    var active = true
    var rate: Double { 15 }
    var palette: [SIMD4<Float>] { [tint] }
    var capacity: Int { Self.capacity }

    static let capacity = ParticleWordmark.grains.count + (ParticleWordmark.grains.count + 156) / 157
    static let haloCount = (ParticleWordmark.grains.count + 156) / 157

    /// Per-grain position and alpha bin, kept between the encoder's two passes.
    final class Workspace {
        var x: [Float]
        var y: [Float]
        var bins: [UInt8]
        var counts = [Int](repeating: 0, count: 5)
        var starts = [Int](repeating: 0, count: 5)

        init() {
            let n = ParticleWordmark.grains.count
            x = [Float](repeating: 0, count: n)
            y = [Float](repeating: 0, count: n)
            bins = [UInt8](repeating: 0, count: n)
        }
    }

    static func makeWorkspace() -> Workspace { Workspace() }

    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace ws: Workspace) -> Int {
        let grains = ParticleWordmark.grains
        let halos = engraved ? 0 : Self.haloCount
        guard grains.count + halos <= capacity else { return 0 }
        let sX = sin(time * 0.65), cX = cos(time * 0.65)
        let sY = sin(time * 0.53), cY = cos(time * 0.53)
        let sL = sin(time * 0.75), cL = cos(time * 0.75)
        let s = Double(scale)
        for bin in 0..<5 { ws.counts[bin] = 0 }
        var haloAt = 0
        // Pass 1: this frame's positions, its `light` (used for the bin and, on every 157th
        // grain, for the halo's alpha — computed once) and the bin populations. The halos are
        // written here because grain order is halo order and halos lead the buffer.
        for (index, grain) in grains.enumerated() {
            // sin(ωt + φ) = sin ωt cos φ + cos ωt sin φ ; cos(ωt + φ) = cos ωt cos φ − sin ωt sin φ
            let x = grain.point.x + (sX * grain.cosPhase + cX * grain.sinPhase) * 0.12
            let y = grain.point.y + (cY * grain.cosPhase - sY * grain.sinPhase) * 0.10
            let light = 0.68 + (sL * grain.cosPhase + cL * grain.sinPhase) * 0.22
            let px = Float(x * s), py = Float(y * s)
            ws.x[index] = px
            ws.y[index] = py
            let bin = min(4, max(0, Int(light * 5)))
            ws.bins[index] = UInt8(bin)
            ws.counts[bin] += 1
            if !engraved && index % 157 == 0 {
                out[haloAt] = ParticlePoint(x: px, y: py, halfWidth: 1.6 * scale, halfHeight: 1.6 * scale,
                                            alpha: Float(light * 0.22), kind: ParticlePoint.halo, color: 0)
                haloAt += 1
            }
        }
        var next = halos
        for bin in 0..<5 {
            ws.starts[bin] = next
            next += ws.counts[bin]
        }
        // Pass 2: the grains, bin by bin from faint to bright, in grain order inside a bin —
        // the order `Canvas` fills its five paths.
        for (index, grain) in grains.enumerated() {
            let bin = Int(ws.bins[index])
            let half = Float(grain.radius * s)
            out[ws.starts[bin]] = ParticlePoint(x: ws.x[index], y: ws.y[index], halfWidth: half, halfHeight: half,
                                                alpha: Float(ParticleWordmark.alpha(bin: bin, engraved: engraved)), kind: ParticlePoint.box, color: 0)
            ws.starts[bin] += 1
        }
        return halos + grains.count
    }
}

/// The navigation dust uses the same positions and grain appearance as its Canvas fallback —
/// in the dock and around Home's selected mode alike.
struct NavigationStarScene: SpriteScene {
    let motion: NavigationStarMotion
    var selection: Int
    /// Dark `#D8E9F2`, light `theme.accent`.
    var tint: SIMD4<Float>
    /// Each grain's feathered halo before its disc; false on paper, where the grains are crisp
    /// dots alone (`NavigationStarCanvas`).
    var halos = true
    var active = true
    /// Every grain's alpha scale (`NavigationStarField.strength`): 1 in the dock.
    var strength = 1.0
    var rate: Double { motion.preferredRate(selection: selection) }
    var palette: [SIMD4<Float>] { [tint] }
    var capacity: Int { Self.capacity }

    static let capacity = NavigationStarMotion.count * 2

    /// The points sampled for this frame. Keeping them here is what makes `encode` pure: the
    /// motion is a stateful integrator, so it must be advanced exactly once per drawn frame
    /// (`advance(to:workspace:)`), never inside the encoder — which also lets the offscreen
    /// parity render drive one motion instead of two in lockstep.
    final class Workspace {
        var points: [CGPoint] = []
    }

    static func makeWorkspace() -> Workspace { Workspace() }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.motion === rhs.motion && lhs.selection == rhs.selection && lhs.tint == rhs.tint
            && lhs.halos == rhs.halos && lhs.active == rhs.active && lhs.strength == rhs.strength
    }

    func advance(to time: Double, workspace: Workspace) {
        workspace.points = motion.sample(time: time, selection: selection)
    }

    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace: Workspace) -> Int {
        Self.encode(points: workspace.points, into: out, capacity: capacity,
                    time: time, width: width, height: height, scale: scale, halos: halos, strength: strength)
    }

    /// The sprites for given unit-space `points` (what `NavigationStarCanvas` draws for them).
    static func encode(points: [CGPoint], into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int,
                       time: Double, width: Double, height: Double, scale: Float, halos: Bool = true,
                       strength: Double = 1) -> Int {
        guard points.count * 2 <= capacity else { return 0 }
        var written = 0
        for (index, point) in points.enumerated() {
            let x = point.x * width, y = point.y * height
            let grain = NavigationStarMotion.appearance(index, time: time)
            let visibility = NavigationStarMotion.textVisibility(at: point)
            let px = Float(x) * scale, py = Float(y) * scale
            if halos {
                let halo = Float(grain.haloRadius) * scale
                out[written] = ParticlePoint(x: px, y: py, halfWidth: halo, halfHeight: halo,
                                            alpha: Float(grain.haloOpacity * visibility * strength), kind: ParticlePoint.halo, color: 0)
                written += 1
            }
            let half = Float(grain.radius) * scale
            out[written] = ParticlePoint(x: px, y: py, halfWidth: half, halfHeight: half,
                                        alpha: Float(grain.opacity * visibility * strength), kind: ParticlePoint.disc, color: 0)
            written += 1
        }
        return written
    }
}

/// `NebulaHalo`: the 72-point orbit in six alpha bins, halos on the points whose seed is above
/// 0.94. Halos first (inline in the Canvas loop), then the bins from faint to bright; every
/// point is an ellipse in the Canvas, so every grain is a disc here. The action capsule's
/// light draws it (`ControlLightScene`); as a scene of its own it is the orbit alone, which is
/// what the parity render checks it as.
struct NebulaHaloScene: SpriteScene {
    var strength: Double
    /// Dark `#D9EDF3`, light `theme.accent`.
    var tint: SIMD4<Float>
    /// False on paper, where the orbit is crisp dots without the soft halos (`NebulaHalo`).
    var halos = true
    var active = true
    var palette: [SIMD4<Float>] { [tint] }
    var capacity: Int { Self.capacity }

    static let count = 72
    static let haloCount = (0..<count).filter { seed($0) > 0.94 }.count
    static let capacity = count + haloCount

    static func seed(_ index: Int) -> Double { Double((index * 37 + 11) % 73) / 73 }

    /// Per-point orbit position, alpha, radius and bin, kept between the encoder's two passes.
    final class Workspace {
        var x = [Double](repeating: 0, count: NebulaHaloScene.count)
        var y = [Double](repeating: 0, count: NebulaHaloScene.count)
        var alpha = [Double](repeating: 0, count: NebulaHaloScene.count)
        var radius = [Double](repeating: 0, count: NebulaHaloScene.count)
        var bins = [UInt8](repeating: 0, count: NebulaHaloScene.count)
        var counts = [Int](repeating: 0, count: 6)
        var starts = [Int](repeating: 0, count: 6)
    }

    static func makeWorkspace() -> Workspace { Workspace() }

    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace: Workspace) -> Int {
        Self.encode(into: out, capacity: capacity, time: time, strength: strength, color: 0, halos: halos,
                    origin: 0, width: width, height: height, scale: scale, workspace: workspace)
    }

    /// The orbit in a `width × height` point frame whose left edge is at `origin` points in the
    /// layer (the action button's halo is four points wider than its capsule on each side).
    static func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double, strength: Double,
                       color: UInt16, halos: Bool = true, origin: Double, width: Double, height: Double, scale: Float,
                       workspace ws: Workspace) -> Int {
        let halosDrawn = halos ? haloCount : 0
        guard count + halosDrawn <= capacity else { return 0 }
        for bin in 0..<6 { ws.counts[bin] = 0 }
        for index in 0..<count {
            let seed = seed(index)
            let depth = Double((index * 19 + 7) % 71) / 71
            let a = Double(index) * 2.39996 + time * (0.33 + depth * 0.17)
            let radial = 0.80 + depth * 0.20 + sin(time * 0.55 + seed * 12) * 0.045
            ws.x[index] = origin + width * (0.5 + cos(a) * 0.46 * radial)
            ws.y[index] = height * (0.5 + sin(a) * 0.40 * radial)
            let wave = 0.5 + 0.5 * sin(a * 2 - time * 0.21)
            let flow = 0.30 + 0.70 * wave * wave
            ws.alpha[index] = (0.22 + depth * 0.60) * flow * strength
            ws.radius[index] = 0.28 + seed * 0.48
            let bin = min(5, max(0, Int(ws.alpha[index] * 6)))
            ws.bins[index] = UInt8(bin)
            ws.counts[bin] += 1
        }
        var next = halosDrawn
        for bin in 0..<6 {
            ws.starts[bin] = next
            next += ws.counts[bin]
        }
        var haloAt = 0
        for index in 0..<count {
            let px = Float(ws.x[index]) * scale, py = Float(ws.y[index]) * scale
            if halos && seed(index) > 0.94 {
                out[haloAt] = ParticlePoint(x: px, y: py, halfWidth: 4 * scale, halfHeight: 4 * scale,
                                            alpha: Float(ws.alpha[index] * 0.26), kind: ParticlePoint.halo, color: color)
                haloAt += 1
            }
            let bin = Int(ws.bins[index])
            let half = Float(ws.radius[index]) * scale
            out[ws.starts[bin]] = ParticlePoint(x: px, y: py, halfWidth: half, halfHeight: half,
                                                alpha: Float((Double(bin) + 0.5) / 6), kind: ParticlePoint.disc, color: color)
            ws.starts[bin] += 1
        }
        return halosDrawn + count
    }
}

/// The light of `LuminousActionButton`: `ControlBreathingLight` — one glow sprite clipped to the
/// capsule — under the `NebulaHalo` orbit, in a layer as wide as the halo (the capsule plus
/// `inset` points on each side). The breath, the alphas and the halo strength follow the
/// button's rules for its state; the stop button has no glow, and neither has any button on
/// paper, where the light theme takes no radial fill and the orbit no soft halos.
struct ControlLightScene: SpriteScene {
    /// Whether the breathing glow is drawn (every appearance but stop, dark only).
    var glows: Bool
    /// The horizontal inset of the capsule inside the layer (4 for a glowing button, else 0).
    var inset: Double
    /// Whether the light breathes (`appearance != .stop && enabled && !busy`); else the phase is 0.25.
    var breathes: Bool
    /// Hovered or keyboard-focused: the brighter glow floor.
    var emphasized: Bool
    /// Disabled or busy: the glow at 30 %.
    var dimmed: Bool
    var haloStrength: Double
    /// 1.9 while busy, else 1.
    var haloSpeed: Double
    /// Glow tint (the core's pearl `#E3F0F6`) and halo tint (dark `#D9EDF3`, light accent).
    var glowTint: SIMD4<Float>
    var haloTint: SIMD4<Float>
    /// The orbit's soft halos (false on paper).
    var halos = true
    var active = true
    var palette: [SIMD4<Float>] { [glowTint, haloTint] }
    var capacity: Int { Self.capacity }

    static let capacity = 1 + NebulaHaloScene.capacity

    /// The halo's workspace; the glow is a single sprite and needs none.
    typealias Workspace = NebulaHaloScene.Workspace
    static func makeWorkspace() -> Workspace { NebulaHaloScene.Workspace() }

    /// The breath phase at `time` (`(1 − cos(2πt / 4.6)) / 2`, 0.25 when not breathing).
    func phase(at time: Double) -> Double {
        breathes ? (1 - cos(time * .pi * 2 / 4.6)) / 2 : 0.25
    }

    func encode(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, time: Double,
                width: Double, height: Double, scale: Float, workspace: Workspace) -> Int {
        guard Self.capacity <= capacity else { return 0 }
        var written = 0
        if glows {
            let p = phase(at: time)
            let alpha = ((emphasized ? 0.075 : 0.028) + p * 0.115) * (dimmed ? 0.30 : 1)
            let capsuleWidth = width - inset * 2
            let radius = capsuleWidth * (0.46 + p * 0.12)
            out[0] = ParticlePoint(x: Float(inset + capsuleWidth * 0.47) * scale, y: Float(height * 0.54) * scale,
                                   halfWidth: Float(radius) * scale, halfHeight: Float(radius * 0.28) * scale,
                                   alpha: Float(alpha), kind: ParticlePoint.glow, color: 0)
            // The glow is one point primitive, and a point is capped at 511 px: the 184 pt capsule
            // needs 429 px at 2×, but a button wider than about 219 pt or a 3× backing scale
            // would have its outer skirt cut off with no error from Metal. Loud here rather than
            // silent on screen.
            assert(out[0].fitsPointSizeLimit,
                   "glow sprite needs \(out[0].spriteSize) px, over the \(ParticlePoint.maxSpriteSize) px point-size limit")
            written = 1
        }
        written += NebulaHaloScene.encode(into: out + written, capacity: capacity - written, time: time * haloSpeed,
                                          strength: haloStrength, color: 1, halos: halos, origin: 0, width: width, height: height,
                                          scale: scale, workspace: workspace)
        return written
    }

    func clip(width: Double, height: Double, scale: Float) -> ParticleFrame.Clip? {
        guard glows else { return nil }
        let half = SIMD2(Float(width / 2 - inset), Float(height / 2))
        return ParticleFrame.Clip(center: SIMD2(Float(width / 2), Float(height / 2)) * scale, halfExtent: half * scale)
    }
}
