import CoreGraphics
import Foundation

/// One GPU point sprite: the unit the Metal path draws instead of a Canvas path element.
///
/// Positions and extents are in *pixels* (the caller multiplies by the backing scale), because
/// a point primitive's size is a pixel size. The layout is shared with the Metal vertex struct
/// (`PointVertex` in the shader source): five floats and two 16-bit integers, 24 bytes, and the
/// encoders below write straight into a `MTLBuffer`, so nothing is copied per frame.
public struct ParticlePoint: Sendable {
    /// A box (an axis-aligned rectangle, what the canvases draw for grains narrower than 1.3 pt
    /// and for the glint strokes): `halfWidth` × `halfHeight` half extents.
    public static let box: UInt16 = 0
    /// A disc of radius `halfWidth`.
    public static let disc: UInt16 = 1
    /// A halo: the tint fading linearly to clear over the radius `halfWidth`
    /// (`ParticleSprites.halo` drawn in a `2 × halfWidth` square).
    public static let halo: UInt16 = 2
    /// A glow: an ellipse of radii `halfWidth × halfHeight` around the centre with a three-stop
    /// falloff — `alpha` at the centre, `0.68 × alpha` at 0.4 of the radius, clear at the rim
    /// (`ControlBreathingLight`'s radial gradient, its context scaled by 0.28 in y). A frame may
    /// clip its glows to a capsule (`ParticleFrame.clip`); the other kinds are never clipped.
    public static let glow: UInt16 = 3

    public var x: Float
    public var y: Float
    public var halfWidth: Float
    public var halfHeight: Float
    /// The sprite's peak alpha; the shader multiplies it by the pixel's coverage.
    public var alpha: Float
    public var kind: UInt16
    /// Index into the palette the caller hands the shader.
    public var color: UInt16

    public init(x: Float, y: Float, halfWidth: Float, halfHeight: Float, alpha: Float, kind: UInt16, color: UInt16) {
        self.x = x; self.y = y; self.halfWidth = halfWidth; self.halfHeight = halfHeight
        self.alpha = alpha; self.kind = kind; self.color = color
    }

    /// The largest point primitive an Apple GPU rasterises. A wider sprite is silently clipped
    /// to this, losing its outermost ring of pixels with no error from Metal.
    public static let maxSpriteSize: Float = 511

    /// The point size the vertex function asks for: wide enough that every pixel the sprite
    /// touches, even partially, gets a fragment (`ceil(2·max(halfWidth, halfHeight)) + 2`).
    public var spriteSize: Float { (2 * max(halfWidth, halfHeight)).rounded(.up) + 2 }

    /// Whether the sprite fits inside the GPU's point-size limit and is drawn whole.
    public var fitsPointSizeLimit: Bool { spriteSize <= Self.maxSpriteSize }
}

extension DustLayout {
    /// The largest number of points one frame of dust can need: a halo for every 101st grain
    /// plus the grains themselves.
    public static func pointCapacity(for grains: Int = NebulaFieldGeometry.count) -> Int {
        grains + grains / 101 + 1
    }

    /// Encodes the laid-out field as the point sprites `LuminousParticleFlow` would fill, in the
    /// same order: every halo first (grain order), then the sixteen band / shade bins from faint
    /// to bright, pearl before ice. `colorBase` is the palette index of the pearl tint (ice is
    /// the next one). Returns the number of points written; 0 when `capacity` is too small.
    public func encodePoints(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, scale: Float, colorBase: UInt16 = 0) -> Int {
        let n = count
        guard n > 0 else { return 0 }
        var counts = [Int](repeating: 0, count: 16)
        var halos = 0
        for j in 0..<n {
            let gi = Int(index[j])
            let a = alpha[j]
            let band = gi % 4 == 0 ? 1 : 0
            let shade = min(7, max(0, Int(a * 20)))
            let bin = band * 8 + shade
            bins[j] = UInt8(bin)
            counts[bin] += 1
            if halo[j] { halos += 1 }
        }
        guard halos + n <= capacity else { return 0 }
        var starts = [Int](repeating: 0, count: 16)
        var next = halos
        for bin in 0..<16 {
            starts[bin] = next
            next += counts[bin]
        }
        var haloAt = 0
        for j in 0..<n {
            let a = alpha[j]
            let d = diameter[j]
            let bin = Int(bins[j])
            let band = UInt16(bin / 8)
            if halo[j] {
                // The sprite is centred on the grain rect's origin, exactly where the canvas puts it.
                out[haloAt] = ParticlePoint(x: x[j] * scale, y: y[j] * scale, halfWidth: 5 * scale, halfHeight: 5 * scale,
                                            alpha: Float(Double(a) * 0.17), kind: ParticlePoint.halo, color: colorBase + band)
                haloAt += 1
            }
            let half = d * 0.5
            let kind = Double(d) < 1.3 ? ParticlePoint.box : ParticlePoint.disc
            out[starts[bin]] = ParticlePoint(x: (x[j] + half) * scale, y: (y[j] + half) * scale,
                                             halfWidth: half * scale, halfHeight: half * scale,
                                             alpha: Float(0.025 + Double(bin % 8) * 0.05), kind: kind, color: colorBase + band)
            starts[bin] += 1
        }
        return halos + n
    }
}

extension StardustGeometry.Workspace {
    /// The largest number of points one frame of the core can need: a lit-dust box for every
    /// grain plus the grains themselves.
    public static func pointCapacity(for grains: Int = StardustGeometry.count) -> Int { grains * 2 }

    /// Encodes the frame as the point sprites `StardustOrganism` would fill at full size (not the
    /// miniature): first the "lit dust" boxes — grains brighter than 0.60, 2.8 radii wide, the
    /// geometry that is blurred into the glow — then the twenty-four tone / alpha batches in
    /// order (pearl, ice, far; each from faint to bright). `side` is the stage side in points;
    /// `toneGain` scales each tone's bin alphas (capped at 1) — the Canvas applies the same gain
    /// to the same bins. Returns the lit count and the grain count; the grains follow the lit
    /// boxes.
    public func encodePoints(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, side: Double, scale: Float,
                             toneGain: SIMD3<Float> = SIMD3(1, 1, 1)) -> (lit: Int, grains: Int) {
        let n = count
        guard n > 0, n * 2 <= capacity else { return (0, 0) }
        var counts = [Int](repeating: 0, count: 24)
        var lit = 0
        for j in 0..<n {
            let a = opacity[j]
            let bin = Int(tone[j]) * 8 + min(7, max(0, Int(a * 8)))
            bins[j] = UInt8(bin)
            counts[bin] += 1
            if a > 0.60 { lit += 1 }
        }
        var starts = [Int](repeating: 0, count: 24)
        var next = lit
        for bin in 0..<24 {
            starts[bin] = next
            next += counts[bin]
        }
        var litAt = 0
        let s = Double(scale)
        for j in 0..<n {
            let r = side * Double(radius[j])
            let cx = Float(Double(x[j]) * side * s), cy = Float(Double(y[j]) * side * s)
            let a = opacity[j]
            let bin = Int(bins[j])
            if a > 0.60 {
                let wide = Float(r * 2.8 * s)
                out[litAt] = ParticlePoint(x: cx, y: cy, halfWidth: wide, halfHeight: wide, alpha: 1, kind: ParticlePoint.box, color: 0)
                litAt += 1
            }
            let half = Float(r * s)
            out[starts[bin]] = ParticlePoint(x: cx, y: cy, halfWidth: half, halfHeight: half,
                                             alpha: min(1, Float((Double(bin % 8) + 0.5) / 8) * toneGain[bin / 8]),
                                             kind: r < 0.65 ? ParticlePoint.box : ParticlePoint.disc, color: UInt16(bin / 8))
            starts[bin] += 1
        }
        return (lit, n)
    }
}

extension StarFieldGeometry {
    /// The largest number of points `count` stars can need: halo, two glint bars and the disc.
    public static func pointCapacity(for count: Int = maxCount) -> Int { count * 4 }

    /// Encodes the first `count` stars at `time` in a `width × height` point canvas as the point
    /// sprites `StellarAtmosphere` would draw, star by star in index order, by the shared `look`:
    /// a bright star in open sky gets its 12 pt halo and the two bars of its glint cross before
    /// its disc. Immersive (idle Home) quiets and keeps glints clear by the window's
    /// `HomeComposition`; elsewhere `keepOut` clears the page's rails. Palette: `colorBase` is
    /// pearl, the next index ice. Returns the number of points written.
    public static func encodePoints(into out: UnsafeMutablePointer<ParticlePoint>, capacity: Int, count: Int, time: Double,
                                    width: Double, height: Double, immersive: Bool, keepOut: SkyKeepOut = SkyKeepOut(),
                                    scale: Float, colorBase: UInt16 = 0) -> Int {
        let n = min(count, maxCount)
        guard n > 0, n * 4 <= capacity else { return 0 }
        let size = CGSize(width: width, height: height)
        let composition = immersive ? HomeComposition(windowWidth: width, windowHeight: height) : nil
        var written = 0
        for index in 0..<n {
            let star = stars[index]
            let position = self.position(index: index, time: time, size: size)
            let look = self.look(star, index: index, at: position, time: time, composition: composition, keepOut: keepOut)
            let color = colorBase + (star.ice ? 1 : 0)
            let px = Float(position.x) * scale, py = Float(position.y) * scale
            if let glint = look.glint {
                out[written] = ParticlePoint(x: px, y: py, halfWidth: 6 * scale, halfHeight: 6 * scale,
                                             alpha: Float(glint.halo), kind: ParticlePoint.halo, color: color)
                let cross = Float(glint.cross)
                out[written + 1] = ParticlePoint(x: px, y: py, halfWidth: 3.5 * scale, halfHeight: 0.25 * scale,
                                                 alpha: cross, kind: ParticlePoint.box, color: color)
                out[written + 2] = ParticlePoint(x: px, y: py, halfWidth: 0.25 * scale, halfHeight: 3.5 * scale,
                                                 alpha: cross, kind: ParticlePoint.box, color: color)
                written += 3
            }
            let half = Float(look.diameter / 2) * scale
            out[written] = ParticlePoint(x: px, y: py, halfWidth: half, halfHeight: half,
                                         alpha: Float(look.opacity), kind: ParticlePoint.disc, color: color)
            written += 1
        }
        return written
    }
}
