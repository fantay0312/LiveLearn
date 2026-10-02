import CoreGraphics
import Foundation

/// Independent damped flights preserve position and velocity when selection changes again.
final class NavigationStarMotion {
    static let strands = 4
    static let grainsPerStrand = 48
    static let count = strands * grainsPerStrand
    static let flightRate = 60.0
    static let idleRate = 30.0
    static let settlingTime = 0.48
    private var positions: [CGPoint] = []
    private var velocities: [CGPoint] = []
    private var lastTime: Double?
    private var motionTime = 0.0
    private var currentSelection: Int?
    private var flightStart = 0.0
    private var flights: [Flight] = []

    private struct Flight {
        let offset: CGPoint
        let slope: CGPoint
        let damping: Double
        let arc: Double

        func sample(age: Double, target: CGPoint, velocity: CGPoint) -> (CGPoint, CGPoint) {
            let t = max(0, age), x = damping * t, decay = exp(-x)
            let dx = offset.x + slope.x * t, dy = offset.y + slope.y * t
            // A short arc starts and ends with zero contribution to velocity.
            let arcScale: Double = exp(2.0) / 4
            let lift = arc * arcScale * x * x * decay
            let liftVelocity = arc * arcScale * damping * x * (2 - x) * decay
            return (
                CGPoint(x: target.x + dx * decay, y: target.y + dy * decay + lift),
                CGPoint(x: velocity.x + (slope.x - damping * dx) * decay,
                        y: velocity.y + (slope.y - damping * dy) * decay + liftVelocity)
            )
        }
    }

    static func target(_ index: Int, selection: Int, time: Double) -> CGPoint {
        orbit(index, selection: selection, time: time).point
    }

    /// The row in points (`OrbitRow`): the orbit's radii are points, its positions unit space.
    private static let width = Double(OrbitRow.size.width), height = Double(OrbitRow.size.height)

    private static func orbit(_ index: Int, selection: Int, time: Double) -> (point: CGPoint, velocity: CGPoint) {
        let center = Double(OrbitRow.centre(selection)) / width
        let strand = index % strands, slot = index / strands
        let lane = Double(strand) - Double(strands - 1) / 2
        let seed = Double((index * 73 + 19) % 199) / 198
        let radialSeed = Double((index * 37 + 11) % 197) / 196
        let speed = 0.25 + Double(strand) * 0.008
        // Each strand keeps its angular slots. Bounded drift cannot collapse the distribution.
        let driftPhase = time * 0.43 + seed * .pi * 2
        let phase = Double(slot) * .pi * 2 / Double(grainsPerStrand) + Double(strand) * 0.047
            + Double(selection) * 0.27 + (seed - 0.5) * 0.075 + time * speed + sin(driftPhase) * 0.012
        let phaseSpeed = speed + cos(driftPhase) * 0.012 * 0.43
        // Spend more angular distance at the narrow ends of the ellipse for even visual density.
        let angle = phase + sin(phase * 2) * 0.15
        let angularSpeed = phaseSpeed * (1 + cos(phase * 2) * 0.30)
        let waveX = angle * 3 + time * 0.21 + seed * 1.2
        let waveY = angle * 2 - time * 0.17 + seed
        let rx = (30 + lane * 0.9 + (seed - 0.5) * 4.4 + sin(waveX) * 0.85) / width
        let ry = (14.5 + lane * 0.45 + (radialSeed - 0.5) * 2.4 + cos(waveY) * 0.5) / height
        let vx = cos(waveX) * 0.85 * (angularSpeed * 3 + 0.21) / width
        let vy = -sin(waveY) * 0.5 * (angularSpeed * 2 - 0.17) / height
        return (CGPoint(x: center + cos(angle) * rx, y: 0.5 + sin(angle) * ry),
                CGPoint(x: -sin(angle) * rx * angularSpeed + cos(angle) * vx,
                        y: cos(angle) * ry * angularSpeed + sin(angle) * vy))
    }

    struct GrainAppearance {
        let radius: Double
        let opacity: Double
        let haloRadius: Double
        let haloOpacity: Double
    }

    static func appearance(_ index: Int, time: Double) -> GrainAppearance {
        let strand = index % strands, slot = index / strands
        let pairedIndex = (slot % (grainsPerStrand / 2)) * strands + strand
        let seed = Double((pairedIndex * 53 + 17) % 101) / 100
        let phase = Double(slot) * .pi * 2 / Double(grainsPerStrand)
        let wave = 0.5 + 0.5 * cos(phase * 2 + time * 0.12 + Double(strand) * 0.4)
        let breath = 0.9 + 0.1 * sin(time * 0.55 + seed * .pi * 2)
        let opacity = (0.25 + seed * 0.30) * (0.45 + wave * wave * 0.55) * breath
        return GrainAppearance(radius: 0.18 + seed * 0.18, opacity: opacity,
                               haloRadius: 1.4 + seed * 1.3, haloOpacity: opacity * 0.12)
    }

    func preferredRate(selection: Int) -> Double {
        guard let currentSelection else { return Self.idleRate }
        return currentSelection != selection || (!flights.isEmpty && motionTime - flightStart < Self.settlingTime)
            ? Self.flightRate : Self.idleRate
    }

    /// Continuous dimming avoids a bright point popping on/off at the edge of a word.
    static func textVisibility(at point: CGPoint) -> Double {
        let x = point.x * width
        let distance = min(abs(x - Double(OrbitRow.centre(0))),
                           min(abs(x - Double(OrbitRow.centre(1))), abs(x - Double(OrbitRow.centre(2)))))
        func smooth(_ value: Double) -> Double {
            let x = min(1, max(0, value))
            return x * x * (3 - 2 * x)
        }
        let outsideX = smooth((distance - 14) / 6)
        let outsideY = smooth((abs(point.y - 0.5) * height - 7) / 5)
        return 0.18 + 0.82 * max(outsideX, outsideY)
    }

    func sample(time: Double, selection: Int, stationary: Bool = false) -> [CGPoint] {
        let t = time.isFinite ? time : 0
        guard !stationary else {
            positions = (0..<Self.count).map { Self.target($0, selection: selection, time: 0) }
            velocities = Array(repeating: .zero, count: Self.count)
            currentSelection = selection
            flights = []
            motionTime = 0
            lastTime = t
            return positions
        }
        if currentSelection == nil {
            currentSelection = selection
            lastTime = t
            positions = (0..<Self.count).map { Self.target($0, selection: selection, time: 0) }
            velocities = (0..<Self.count).map { Self.orbit($0, selection: selection, time: 0).velocity }
            return positions
        }
        let elapsed = max(0, t - (lastTime ?? t))
        // Resume from the last visible pose after suspension; never fast-forward a short flight.
        let delta = elapsed > 0.25 ? 0 : min(0.1, elapsed)
        lastTime = t
        motionTime += delta
        advance(selection: currentSelection ?? selection)
        if currentSelection != selection {
            currentSelection = selection
            flightStart = motionTime
            flights = positions.indices.map { index in
                let seed = Double((index * 7) % Self.count) / Double(Self.count - 1)
                let target = Self.orbit(index, selection: selection, time: motionTime)
                let offset = CGPoint(x: positions[index].x - target.point.x, y: positions[index].y - target.point.y)
                let damping = 20.0 + Double(index % 5) * 1.25
                let slope = CGPoint(x: velocities[index].x - target.velocity.x + damping * offset.x,
                                    y: velocities[index].y - target.velocity.y + damping * offset.y)
                let upper = index.isMultiple(of: 2)
                let room = upper ? min(positions[index].y, target.point.y)
                    : 1 - max(positions[index].y, target.point.y)
                let arc = min(max(0, room) * 0.65, 0.09 + seed * 0.09) * (upper ? -1 : 1)
                return Flight(offset: offset, slope: slope, damping: damping, arc: arc)
            }
        }
        return positions
    }

    private func advance(selection: Int) {
        let age = motionTime - flightStart
        if age > 0.8 { flights = [] }
        for index in positions.indices {
            let target = Self.orbit(index, selection: selection, time: motionTime)
            let (point, velocity) = index < flights.count
                ? flights[index].sample(age: age, target: target.point, velocity: target.velocity)
                : (target.point, target.velocity)
            positions[index] = CGPoint(x: min(0.99, max(0.01, point.x)), y: min(0.97, max(0.03, point.y)))
            velocities[index] = CGPoint(x: positions[index].x == point.x ? velocity.x : 0,
                                        y: positions[index].y == point.y ? velocity.y : 0)
        }
    }
}
