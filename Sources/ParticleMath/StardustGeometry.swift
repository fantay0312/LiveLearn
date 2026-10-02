import CoreGraphics
import Foundation

/// The core's state as light: how bright its lit current burns, how much light the whole body
/// gives, and how far its tints have gone to silver — so a still frame of idle, running and
/// paused can be told apart without the motion. `StardustMotion` eases between moods at the
/// activity's rate; a static frame takes its target.
public struct StardustMood: Equatable, Sendable {
    /// Opacity gain on the lit current (the pearl grains), blended in over current 0.35…0.65.
    public var highlight: Double
    /// Opacity gain on every grain.
    public var body: Double
    /// 0 keeps the ice tints, 1 is the paused silver (the palette's business, not the geometry's).
    public var silver: Double

    public init(highlight: Double, body: Double, silver: Double) {
        self.highlight = highlight; self.body = body; self.silver = silver
    }

    /// At rest the current already sparkles a little above the body (the grains carry the light
    /// the old central haze gave).
    public static let idle = StardustMood(highlight: 1.08, body: 1, silver: 0)
    /// Ignited: the current's pearl highlights a fifth brighter than at rest.
    public static let running = StardustMood(highlight: 1.30, body: 1, silver: 0)
    /// Held breath: idle's current, slightly dimmer, silver — still a lit core (about three
    /// quarters of idle's bright grains in a still), not a faded or disabled one.
    public static let paused = StardustMood(highlight: 1.08, body: 0.94, silver: 1)

    /// This mood moved `amount` (0…1) of the way to `target`.
    public func approaching(_ target: StardustMood, by amount: Double) -> StardustMood {
        let k = min(1, max(0, amount))
        return StardustMood(highlight: highlight + (target.highlight - highlight) * k,
                            body: body + (target.body - body) * k,
                            silver: silver + (target.silver - silver) * k)
    }
}

/// A volumetric dust cloud with folded currents, rather than particles on an outline.
///
/// The per-frame work is arranged so the 6,400 grains cost a handful of vectorised passes:
/// the two terms whose phase is fixed per seed (the meridian wobble and the flicker) use the
/// angle-addition identity against tabulated sines, and the five terms that depend on the
/// wobbled longitude go through vForce in bulk. The scalar loop that remains is plain
/// arithmetic on preallocated planes.
///
/// The material (2026-09-27): grains come in three magnitudes rather than one continuous size,
/// the outer shell thins out instead of ending at its densest (so the rim dissolves into the
/// sky rather than drawing a circle), the faint body brightens toward the projected centre (the
/// light a haze used to lay there now comes from grains), and the cloud is centred in its stage.
public enum StardustGeometry {
    public struct Grain {
        public let point: CGPoint
        public let radius: Double
        public let opacity: Double
        public let tone: Int
    }

    public static let count = 6400

    /// The cloud's centre in unit stage space. Centred, so the core's centre is the stage's
    /// and the page composes on one point; the feathered rim needs the headroom on both sides.
    public static let center = CGPoint(x: 0.5, y: 0.5)

    /// A grain's magnitude from its size seed: radius as a fraction of the stage side (before
    /// the current swells it by up to 14 %) and an opacity gain. Half fine dust, 40 % medium,
    /// 10 % bright — at 360 pt about 0.65, 1.05 and 1.6 pt across.
    static func magnitude(_ seed: Double) -> (radius: Double, light: Double) {
        seed < 0.50 ? (0.00090, 1.0) : (seed < 0.90 ? (0.00148, 1.06) : (0.00225, 1.12))
    }

    /// The shell's radius for a uniform `u`: a triangular distribution over 0.58…1.08 peaking at
    /// 0.90 (its inverse CDF). The old shell was densest at its outer edge, which projected as a
    /// hard circle; this one thins to nothing past the rim.
    static func shellRadius(_ u: Double) -> Double {
        let mode = 0.64
        let x = u < mode ? (u * mode).squareRoot() : 1 - ((1 - u) * (1 - mode)).squareRoot()
        return 0.58 + 0.50 * x
    }

    private final class Table: @unchecked Sendable {
        let lon, radius, size, light: FloatPlane
        let sinLat, cosLat, lat37, lat17, lat64, lat2: FloatPlane
        /// sin / cos of `lat · 2.6` (the wobble) and of `variation · 12` (the flicker).
        let sA, cA, sV, cV: FloatPlane

        init() {
            let n = StardustGeometry.count
            lon = FloatPlane(n); radius = FloatPlane(n); size = FloatPlane(n); light = FloatPlane(n)
            sinLat = FloatPlane(n); cosLat = FloatPlane(n)
            lat37 = FloatPlane(n); lat17 = FloatPlane(n); lat64 = FloatPlane(n); lat2 = FloatPlane(n)
            sA = FloatPlane(n); cA = FloatPlane(n); sV = FloatPlane(n); cV = FloatPlane(n)
            var state: UInt64 = 0x67AF2193
            func random() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(UInt64.max >> 11)
            }
            // One draw per quantity, in the original order, so every grain keeps its longitude,
            // latitude and phases: only how far out it sits and how it shines changed.
            for index in 0..<n {
                let longitude = random() * .pi * 2
                let latitude = asin(random() * 2 - 1)
                let r = index % 3 == 0 ? pow(random(), 1.0 / 3) * 0.87 : StardustGeometry.shellRadius(random())
                let variation = random()
                let s = random()
                let magnitude = StardustGeometry.magnitude(s)
                // Past 0.93 the shell's grains dim toward the rim (to 30 % at its edge).
                let rim = min(1, max(0.30, (1.13 - r) / 0.20))
                lon.base[index] = Float(longitude)
                radius.base[index] = Float(r)
                size.base[index] = Float(magnitude.radius)
                light.base[index] = Float(magnitude.light * rim)
                sinLat.base[index] = Float(sin(latitude))
                cosLat.base[index] = Float(cos(latitude))
                lat37.base[index] = Float(latitude * 3.7)
                lat17.base[index] = Float(latitude * 1.7)
                lat64.base[index] = Float(latitude * 6.4)
                lat2.base[index] = Float(latitude * 2)
                sA.base[index] = Float(sin(latitude * 2.6)); cA.base[index] = Float(cos(latitude * 2.6))
                sV.base[index] = Float(sin(variation * 12)); cV.base[index] = Float(cos(variation * 12))
            }
        }
    }

    private static let table = Table()

    /// One frame of grains plus the scratch planes the vector passes need. Owned by the view
    /// and refilled in place.
    public final class Workspace {
        public let capacity: Int
        public private(set) var count = 0
        /// Unit-space position (0…1 of the stage), radius as a fraction of the stage side,
        /// opacity 0…1 and tone 0 / 1 / 2 (pearl current / lit ice / far ice).
        public let x: UnsafeMutablePointer<Float>
        public let y: UnsafeMutablePointer<Float>
        public let radius: UnsafeMutablePointer<Float>
        public let opacity: UnsafeMutablePointer<Float>
        public let tone: UnsafeMutablePointer<UInt8>
        fileprivate let flow, a1, a2, a3, a4, s1, s2, c3, s4, s5, c5: FloatPlane
        private let planes: [FloatPlane]
        private let tonePlane: UnsafeMutablePointer<UInt8>
        /// Scratch for the point encoder: each grain's tone / alpha bin.
        let bins: UnsafeMutablePointer<UInt8>

        public init(capacity: Int = StardustGeometry.count) {
            self.capacity = capacity
            let p = (0..<4).map { _ in FloatPlane(capacity) }
            planes = p
            x = p[0].base; y = p[1].base; radius = p[2].base; opacity = p[3].base
            flow = FloatPlane(capacity)
            a1 = FloatPlane(capacity); a2 = FloatPlane(capacity); a3 = FloatPlane(capacity); a4 = FloatPlane(capacity)
            s1 = FloatPlane(capacity); s2 = FloatPlane(capacity); c3 = FloatPlane(capacity)
            s4 = FloatPlane(capacity); s5 = FloatPlane(capacity); c5 = FloatPlane(capacity)
            tonePlane = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, capacity))
            tonePlane.initialize(repeating: 0, count: max(1, capacity))
            tone = tonePlane
            bins = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, capacity))
            bins.initialize(repeating: 0, count: max(1, capacity))
        }

        deinit {
            tonePlane.deallocate()
            bins.deallocate()
        }
        fileprivate func setCount(_ n: Int) { count = n }
    }

    /// Fills `ws` with every `sampleStride`-th grain at `time`. `pointer` is in unit space.
    public static func fill(_ ws: Workspace, time: Double, pointer: CGPoint? = nil, influence: Double = 0,
                            pulse: Double = 0, sampleStride: Int = 1, activity: Double = 0, mood: StardustMood = .idle) {
        let t = time.isFinite ? time : 0
        let step = max(1, sampleStride)
        let n = min(ws.capacity, (count + step - 1) / step)
        ws.setCount(n)
        guard n > 0 else { return }
        let energy = min(1, max(0, activity))
        let pulseAmount = Float(min(1, max(0, pulse)))
        let breath = Float(1 + sin(t * 0.84) * (0.024 + energy * 0.055)) + pulseAmount * 0.11
        let turn = t * 0.095
        let tilt = -0.40 + sin(t * 0.17) * 0.07
        let cy = Float(cos(turn)), sy = Float(sin(turn)), ct = Float(cos(tilt)), st = Float(sin(tilt))
        // Per-frame constants for the angle-addition terms and the vForce arguments.
        let wC = Float(cos(t * 0.22)), wS = Float(sin(t * 0.22))
        let fC = Float(cos(t * 0.63)), fS = Float(sin(t * 0.63))
        let t13 = Float(t * 0.13), t17 = Float(t * 0.17), t11 = Float(t * 0.11), t23 = Float(t * 0.23)
        let highlight = Float(mood.highlight) - 1, body = Float(mood.body)
        let originX = Float(center.x), originY = Float(center.y)
        // The body's faint floor rises toward the projected centre, fading out by 0.55 of the
        // cloud's radius: with no haze behind them, the grains alone left the middle of the ball
        // darker than the ring around it, and the volume read as a hollow shell.
        let centreReach: Float = 0.345 * 0.55
        let centreReachInv = 1 / (centreReach * centreReach)
        let tb = table
        let lon = tb.lon.base, rad = tb.radius.base, size = tb.size.base, light = tb.light.base
        let sinLat = tb.sinLat.base, cosLat = tb.cosLat.base
        let lat37 = tb.lat37.base, lat17 = tb.lat17.base, lat64 = tb.lat64.base, lat2 = tb.lat2.base
        let sA = tb.sA.base, cA = tb.cA.base, sV = tb.sV.base, cV = tb.cV.base
        let flow = ws.flow.base, a1 = ws.a1.base, a2 = ws.a2.base, a3 = ws.a3.base, a4 = ws.a4.base
        // Pass 1: the wobbled longitude and the five arguments that depend on it.
        var i = 0
        for j in 0..<n {
            let f = lon[i] + (sA[i] * wC + cA[i] * wS) * 0.30
            flow[j] = f
            a1[j] = f * 2.1 + lat37[i] + t13
            a2[j] = f * 4.3 - lat17[i] - t17
            a3[j] = f * 0.9 + lat64[i] + t11
            a4[j] = f * 3 + lat2[i] + t23
            i += step
        }
        ParticleTrig.sin(ws.s1.base, a1, n)
        ParticleTrig.sin(ws.s2.base, a2, n)
        ParticleTrig.cos(ws.c3.base, a3, n)
        ParticleTrig.sin(ws.s4.base, a4, n)
        ParticleTrig.sin(ws.s5.base, flow, n)
        ParticleTrig.cos(ws.c5.base, flow, n)
        // Pass 2: fold, projection, light.
        let s1 = ws.s1.base, s2 = ws.s2.base, c3 = ws.c3.base, s4 = ws.s4.base, s5 = ws.s5.base, c5 = ws.c5.base
        let ox = ws.x, oy = ws.y, orad = ws.radius, oop = ws.opacity, otone = ws.tone
        let pull: (Float, Float, Float)? = {
            guard let pointer, pointer.x.isFinite, pointer.y.isFinite, influence.isFinite else { return nil }
            let strength = Float(min(1, max(0, influence))) * 0.10
            return strength > 0 ? (Float(pointer.x), Float(pointer.y), strength) : nil
        }()
        i = 0
        for j in 0..<n {
            let fold = 0.48 + s1[j] * 0.30 + s2[j] * 0.18 + c3[j] * 0.10
            let cur = min(1, max(0, fold))
            let current = cur * cur.squareRoot()          // pow(cur, 1.5)
            let r = rad[i] * (1 + s4[j] * 0.045) * breath
            let cl = cosLat[i]
            let x = c5[j] * cl * r, y = sinLat[i] * r, z = s5[j] * cl * r
            let rx = x * cy + z * sy, rz = z * cy - x * sy
            let ry = y * ct - rx * st
            let sx = rx * ct + y * st
            let perspective = 1 / (1 - rz * 0.16)
            let qx = sx * perspective * 0.345, qy = ry * perspective * 0.345
            var px = originX + qx
            var py = originY + qy
            // Where the grain projects before the pointer pulls it, so a pull moves light
            // without changing it.
            let centreFill = max(0, 1 - (qx * qx + qy * qy) * centreReachInv)
            if let pull {
                let dx = pull.0 - px, dy = pull.1 - py
                let d2 = dx * dx + dy * dy
                // exp(−d²/0.065) is below 1e-4 past d² ≈ 0.6: nothing to move out there.
                if d2 < 0.6 {
                    let p = expf(-d2 / 0.065) * pull.2
                    px += dx * p
                    py += dy * p
                }
            }
            let front = 0.44 + (rz + 1) * 0.28
            let flicker = 0.88 + 0.12 * (sV[i] * fC + cV[i] * fS)
            // The mood's highlight reaches the lit current only, eased in across the pearl
            // threshold (0.50) so no grain steps in brightness as it crosses it.
            let lit = min(1, max(0, (current - 0.35) / 0.30))
            let gain = body * (1 + highlight * lit * lit * (3 - 2 * lit))
            ox[j] = px
            oy[j] = py
            oop[j] = min(0.96, (0.16 + 0.14 * centreFill + current * 0.88) * front * flicker * light[i] * gain + pulseAmount * 0.20)
            orad[j] = size[i] * (0.86 + current * 0.28)
            otone[j] = current > 0.50 ? 0 : (rz > 0 ? 1 : 2)
            i += step
        }
    }

    /// The allocating form, for tests and one-off consumers.
    public static func grains(time: Double, pointer: CGPoint? = nil, influence: Double = 0, pulse: Double = 0,
                              sampleStride: Int = 1, activity: Double = 0, mood: StardustMood = .idle) -> [Grain] {
        let ws = Workspace()
        fill(ws, time: time, pointer: pointer, influence: influence, pulse: pulse, sampleStride: sampleStride,
             activity: activity, mood: mood)
        var out: [Grain] = []
        out.reserveCapacity(ws.count)
        for j in 0..<ws.count {
            out.append(Grain(point: CGPoint(x: Double(ws.x[j]), y: Double(ws.y[j])), radius: Double(ws.radius[j]),
                             opacity: Double(ws.opacity[j]), tone: Int(ws.tone[j])))
        }
        return out
    }
}
