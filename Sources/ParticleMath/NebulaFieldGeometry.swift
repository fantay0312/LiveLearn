import CoreGraphics
import Foundation

/// Deterministic random clumps with overlapping scales and continuously changing local drift.
///
/// Every term of the drift is `sin(a + ωt)` with `a` fixed per seed, so it is evaluated in its
/// angle-addition form: `sin a · cos ωt + cos a · sin ωt`, with `sin a` / `cos a` tabulated once
/// and only twelve `sin` / `cos` calls per frame for the whole field. The positions are exactly
/// those of the original per-grain trigonometry; the field just no longer spends five
/// transcendental calls and an allocation per grain per frame.
public enum NebulaFieldGeometry {
    public struct Grain {
        public let point: CGPoint
        public let depth: Double
        public let opacity: Double
    }

    public static let count = 5200

    /// Open, asymmetrical formations. Dust samples these curves with broad random scatter;
    /// brighter stars mark only a few landmarks, never a neat connected line.
    public static func formation(_ index: Int, progress: Double, time: Double = 0) -> CGPoint {
        let u = min(1, max(0, progress))
        switch index % 4 {
        case 0:
            let a = -2.5 + u * 4.9 + sin(time * 0.10) * 0.12
            let r = 0.035 + u * 0.14
            return CGPoint(x: 0.20 + cos(a) * r, y: 0.27 + sin(a) * r * 0.85)
        case 1:
            let a = -2.2 + u * 3.7 + cos(time * 0.09) * 0.10
            return CGPoint(x: 0.80 + cos(a) * (0.09 + u * 0.04), y: 0.29 + sin(a) * 0.13)
        case 2:
            return CGPoint(x: 0.07 + u * 0.24, y: 0.73 + sin(u * 5.2 + 0.3 + time * 0.05) * 0.10 - u * 0.04)
        default:
            let a = -1.7 + u * 4.2 + sin(time * 0.08) * 0.09
            let r = 0.025 + u * 0.115
            return CGPoint(x: 0.82 + cos(a) * r, y: 0.73 + sin(a) * r)
        }
    }

    /// Seed constants, structure-of-arrays. `s`/`c` are the sine and cosine of the six fixed
    /// angles of the original drift expression (see `fill`).
    private final class Table: @unchecked Sendable {
        let x, y, depth, base: FloatPlane
        let s1, c1, s2, c2, s3, c3, s4, c4, s5, c5, s6, c6: FloatPlane

        init() {
            let n = NebulaFieldGeometry.count
            x = FloatPlane(n); y = FloatPlane(n); depth = FloatPlane(n); base = FloatPlane(n)
            s1 = FloatPlane(n); c1 = FloatPlane(n); s2 = FloatPlane(n); c2 = FloatPlane(n)
            s3 = FloatPlane(n); c3 = FloatPlane(n); s4 = FloatPlane(n); c4 = FloatPlane(n)
            s5 = FloatPlane(n); c5 = FloatPlane(n); s6 = FloatPlane(n); c6 = FloatPlane(n)
            var state: UInt64 = 0x919AC397
            func random() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(UInt64.max >> 11)
            }
            // Broad unequal clouds, a loose bridge around the core and a sparse interstitial field.
            let centers: [(Double, Double, Double, Double)] = [
                (0.19, 0.40, 0.18, 0.17), (0.80, 0.35, 0.19, 0.14),
                (0.34, 0.17, 0.18, 0.09), (0.72, 0.64, 0.20, 0.16)
            ]
            for index in 0..<n {
                let c = centers[index % centers.count]
                let a = random() * .pi * 2
                let radius = sqrt(-2 * log(max(0.0001, random()))) * 0.66
                let point: CGPoint
                if index % 3 == 0 {
                    point = CGPoint(x: random(), y: random())
                } else if index % 7 == 0 {
                    point = CGPoint(x: c.0 + cos(a) * radius * c.2, y: c.1 + sin(a) * radius * c.3)
                } else {
                    let axis = NebulaFieldGeometry.formation(index % 4, progress: random())
                    let spread = 0.018 + random() * 0.032
                    point = CGPoint(x: axis.x + cos(a) * radius * spread, y: axis.y + sin(a) * radius * spread)
                }
                let phase = random() * .pi * 2
                let d = random()
                x.base[index] = Float(point.x)
                y.base[index] = Float(point.y)
                depth.base[index] = Float(d)
                base.base[index] = Float(0.16 + d * 0.45)
                // The six fixed angles of the original expression:
                //   dx = sin(y·9 + 0.32t + φ)·0.022 + sin(0.55t + 2φ)·0.012
                //   dy = cos(x·8 − 0.30t + 0.8φ)·0.025 + sin(0.42t + φ)·0.018
                //   density = 0.57 + 0.20·sin(x·19 + y·11 + 0.15t) + 0.12·cos(y·27 − 0.17t + φ)
                let a1 = point.y * 9 + phase, a2 = phase * 2, a3 = point.x * 8 + phase * 0.8
                let a4 = phase, a5 = point.x * 19 + point.y * 11, a6 = point.y * 27 + phase
                s1.base[index] = Float(sin(a1)); c1.base[index] = Float(cos(a1))
                s2.base[index] = Float(sin(a2)); c2.base[index] = Float(cos(a2))
                s3.base[index] = Float(sin(a3)); c3.base[index] = Float(cos(a3))
                s4.base[index] = Float(sin(a4)); c4.base[index] = Float(cos(a4))
                s5.base[index] = Float(sin(a5)); c5.base[index] = Float(cos(a5))
                s6.base[index] = Float(sin(a6)); c6.base[index] = Float(cos(a6))
            }
        }
    }

    private static let table = Table()

    /// The field for one frame: unit-space positions, depth and the geometry's own opacity.
    /// Owned by the view and refilled in place, so a frame allocates nothing.
    public final class Field {
        public let capacity: Int
        public private(set) var count = 0
        public let x: UnsafeMutablePointer<Float>
        public let y: UnsafeMutablePointer<Float>
        public let depth: UnsafeMutablePointer<Float>
        public let opacity: UnsafeMutablePointer<Float>
        private let planes: [FloatPlane]

        public init(capacity: Int = NebulaFieldGeometry.count) {
            self.capacity = capacity
            let p = (0..<4).map { _ in FloatPlane(capacity) }
            planes = p
            x = p[0].base; y = p[1].base; depth = p[2].base; opacity = p[3].base
        }

        fileprivate func setCount(_ n: Int) { count = n }
    }

    /// Fills `field` with every `sampleStride`-th grain at `time`.
    public static func fill(_ field: Field, time: Double, sampleStride: Int = 1) {
        let t = time.isFinite ? time : 0
        let step = max(1, sampleStride)
        let n = min(field.capacity, (count + step - 1) / step)
        field.setCount(n)
        // Per-frame constants of the angle-addition form (Double, then Float: the seed angles
        // are small, only ωt grows with the session clock).
        let cT1 = Float(cos(t * 0.32)), sT1 = Float(sin(t * 0.32))
        let cT2 = Float(cos(t * 0.55)), sT2 = Float(sin(t * 0.55))
        let cT3 = Float(cos(-t * 0.30)), sT3 = Float(sin(-t * 0.30))
        let cT4 = Float(cos(t * 0.42)), sT4 = Float(sin(t * 0.42))
        let cT5 = Float(cos(t * 0.15)), sT5 = Float(sin(t * 0.15))
        let cT6 = Float(cos(-t * 0.17)), sT6 = Float(sin(-t * 0.17))
        let tb = table
        let x = tb.x.base, y = tb.y.base, depth = tb.depth.base, base = tb.base.base
        let s1 = tb.s1.base, c1 = tb.c1.base, s2 = tb.s2.base, c2 = tb.c2.base
        let s3 = tb.s3.base, c3 = tb.c3.base, s4 = tb.s4.base, c4 = tb.c4.base
        let s5 = tb.s5.base, c5 = tb.c5.base, s6 = tb.s6.base, c6 = tb.c6.base
        let ox = field.x, oy = field.y, od = field.depth, oo = field.opacity
        var i = 0, j = 0
        while j < n {
            // sin(a + T) = sin a cos T + cos a sin T ; cos(a + T) = cos a cos T − sin a sin T
            let dx = (s1[i] * cT1 + c1[i] * sT1) * 0.022 + (s2[i] * cT2 + c2[i] * sT2) * 0.012
            let dy = (c3[i] * cT3 - s3[i] * sT3) * 0.025 + (s4[i] * cT4 + c4[i] * sT4) * 0.018
            let density = 0.57 + 0.20 * (s5[i] * cT5 + c5[i] * sT5) + 0.12 * (c6[i] * cT6 - s6[i] * sT6)
            ox[j] = x[i] + dx
            oy[j] = y[i] + dy
            od[j] = depth[i]
            oo[j] = base[i] * density
            i += step
            j += 1
        }
    }

    /// The allocating form, for tests and one-off consumers.
    public static func grains(time: Double, sampleStride: Int = 1) -> [Grain] {
        let field = Field()
        fill(field, time: time, sampleStride: sampleStride)
        var out: [Grain] = []
        out.reserveCapacity(field.count)
        for j in 0..<field.count {
            out.append(Grain(point: CGPoint(x: Double(field.x[j]), y: Double(field.y[j])),
                             depth: Double(field.depth[j]), opacity: Double(field.opacity[j])))
        }
        return out
    }
}

/// Screen-space layout of the dust field for `LuminousParticleFlow`: the two fades that keep
/// the core and the controls dark, the keep-out that holds bright dust off Home's words, the
/// pointer displacement, and the size / band / shade / halo of each grain, computed in bulk so
/// the view only builds paths.
public final class DustLayout {
    public let capacity: Int
    public private(set) var count = 0
    /// Screen position, diameter in points and final alpha of every visible grain.
    public let x: UnsafeMutablePointer<Float>
    public let y: UnsafeMutablePointer<Float>
    public let diameter: UnsafeMutablePointer<Float>
    public let alpha: UnsafeMutablePointer<Float>
    /// The grain's index in the field (every fourth grain is the second tint).
    public let index: UnsafeMutablePointer<Int32>
    /// Whether the grain carries a 10 pt halo: every 101st grain brighter than 0.20, in open
    /// sky. Decided here once, so the Canvas and the point encoder cannot disagree.
    public let halo: UnsafeMutablePointer<Bool>
    private let e1, e2, f1, f2: FloatPlane
    private let planes: [FloatPlane]
    private let indexPlane: UnsafeMutablePointer<Int32>
    private let haloPlane: UnsafeMutablePointer<Bool>
    /// Scratch for the point encoder: each kept grain's band / shade bin.
    let bins: UnsafeMutablePointer<UInt8>

    public init(capacity: Int = NebulaFieldGeometry.count) {
        self.capacity = capacity
        let p = (0..<4).map { _ in FloatPlane(capacity) }
        planes = p
        x = p[0].base; y = p[1].base; diameter = p[2].base; alpha = p[3].base
        e1 = FloatPlane(capacity); e2 = FloatPlane(capacity); f1 = FloatPlane(capacity); f2 = FloatPlane(capacity)
        indexPlane = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, capacity))
        indexPlane.initialize(repeating: 0, count: max(1, capacity))
        index = indexPlane
        haloPlane = UnsafeMutablePointer<Bool>.allocate(capacity: max(1, capacity))
        haloPlane.initialize(repeating: false, count: max(1, capacity))
        halo = haloPlane
        bins = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, capacity))
        bins.initialize(repeating: 0, count: max(1, capacity))
    }

    deinit {
        indexPlane.deallocate()
        haloPlane.deallocate()
        bins.deallocate()
    }

    /// Lays the field out in a `width × height` canvas — the Home window, whose
    /// `HomeComposition` places the fades. `displace` is the pointer's displacement for a screen
    /// point, or nil when nothing is pushing the dust; grains fainter than the visibility floor
    /// are dropped here.
    public func layout(_ field: NebulaFieldGeometry.Field, width: Float, height: Float, intensity: Float,
                       displace: ((Float, Float) -> (Float, Float))?) {
        let n = min(field.count, capacity)
        guard n > 0, width > 0, height > 0 else { count = 0; return }
        let fx = field.x, fy = field.y, fd = field.depth, fo = field.opacity
        let home = HomeComposition(windowWidth: Double(width), windowHeight: Double(height))
        // The core fade sits on the core and reaches as far as its grains; the control fade is a
        // super-ellipse over the column from the capsule down to the dock, 20 pt past each end.
        let cx = Float(home.axisX), coreY = Float(home.windowCoreCenter.y)
        let invRadius = Float(1 / home.coreRadius)
        let columnTop = Float(home.windowCapsuleTop), columnBottom = Float(home.dockTop)
        let controlY = (columnTop + columnBottom) / 2, controlHalf = (columnBottom - columnTop) / 2 + 20
        let a1 = e1.base, a2 = e2.base
        // Pass 1: positions and the two exponent arguments.
        for j in 0..<n {
            var px = fx[j] * width, py = fy[j] * height
            if let displace {
                let shift = displace(px, py)
                px += shift.0
                py += shift.1
            }
            x[j] = px
            y[j] = py
            let dx = px - cx, dy = py - coreY
            let u = (dx * dx + dy * dy).squareRoot() * invRadius
            a1[j] = -(u * u * u)
            let vx = dx / 220, vy = (py - controlY) / controlHalf
            let vx2 = vx * vx, vy2 = vy * vy
            a2[j] = -(vx2 * vx2 + vy2 * vy2)
        }
        ParticleTrig.exp(f1.base, a1, n)
        ParticleTrig.exp(f2.base, a2, n)
        // Pass 2: fades, keep-out, alpha, size; compact the visible grains. Near a word or a
        // control a grain may stay (the sky keeps its texture there) but never brighter than
        // 0.30, and never with a halo.
        let r1 = f1.base, r2 = f2.base
        var kept = 0
        for j in 0..<n {
            let coreFade = 0.22 + 0.78 * (1 - r1[j])
            let controlFade = 0.26 + 0.74 * (1 - r2[j])
            var a = coreFade * controlFade * fo[j] * intensity
            guard a > 0.025 else { continue }
            // Only a grain above 0.20 can meet the 0.30 cap or carry a halo, so the rest (most
            // of the field) skip the distance: the result is the same either way.
            let clear: Float = a > 0.20 ? Float(home.clearance(x: Double(x[j]), y: Double(y[j]))) : 1
            a = min(a, 0.30 + 0.70 * clear)
            if kept != j {
                x[kept] = x[j]
                y[kept] = y[j]
            }
            alpha[kept] = a
            diameter[kept] = 0.45 + fd[j] * 0.95
            index[kept] = Int32(j)
            halo[kept] = j % 101 == 0 && a > 0.20 && clear >= 1
            kept += 1
        }
        count = kept
    }
}
