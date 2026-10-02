import Foundation
import Testing
@testable import LiveLearnApp

struct NavigationStarMotionTests {
    /// The orbit row in points: the motion's positions are unit space.
    private let w = Double(OrbitRow.size.width), h = Double(OrbitRow.size.height)

    @Test func dustStaysDistributedAndOpticallyBalancedOverTenMinutes() {
        for selection in 0...2 {
            let center = Double(OrbitRow.centre(selection)) / w
            for time in stride(from: 0.0, through: 600, by: 5) {
                var quadrants = [Int](repeating: 0, count: 4)
                var light = [Double](repeating: 0, count: 4)
                var angles: [Double] = []
                for index in 0..<NavigationStarMotion.count {
                    let point = NavigationStarMotion.target(index, selection: selection, time: time)
                    let dx = (point.x - center) * w, dy = (point.y - 0.5) * h
                    let quadrant = (dx >= 0 ? 1 : 0) + (dy >= 0 ? 2 : 0)
                    quadrants[quadrant] += 1
                    let grain = NavigationStarMotion.appearance(index, time: time)
                    light[quadrant] += (grain.opacity * grain.radius * grain.radius
                        + grain.haloOpacity * grain.haloRadius * grain.haloRadius / 3)
                        * NavigationStarMotion.textVisibility(at: point)
                    angles.append(atan2(dy / 14.5, dx / 30))
                    #expect(abs(dx) > 16 || abs(dy) > 9)
                }
                #expect(quadrants.allSatisfy {
                    let share = Double($0) / Double(NavigationStarMotion.count)
                    return share >= 0.18 && share <= 0.32
                })
                let total = light.reduce(0, +)
                #expect(light.allSatisfy { $0 / total < 0.42 && $0 / total > 0.12 })
                angles.sort()
                let gaps = zip(angles, angles.dropFirst()).map { $1 - $0 }
                    + [angles[0] + .pi * 2 - angles[angles.count - 1]]
                #expect((gaps.max() ?? 0) < 0.30)
            }
        }
    }

    @Test func firstAppearanceStartsAtTheSelectedLabel() {
        let motion = NavigationStarMotion()
        let points = motion.sample(time: 0, selection: 1)
        #expect(points == (0..<NavigationStarMotion.count).map { NavigationStarMotion.target($0, selection: 1, time: 0) })
        #expect(motion.preferredRate(selection: 1) == NavigationStarMotion.idleRate)
    }

    @Test func selectionRespondsImmediatelyAndSettlesWithinFourHundredMilliseconds() {
        let motion = NavigationStarMotion()
        let start = motion.sample(time: 0, selection: 0)
        _ = motion.sample(time: 0, selection: 2)
        var points: [CGPoint] = []
        for frame in 1...6 { points = motion.sample(time: Double(frame) / 60, selection: 2) }
        let travel = zip(start, points).map { $1.x - $0.x }.reduce(0, +) / Double(points.count)
        #expect(travel > 0.36)
        for frame in 7...24 { points = motion.sample(time: Double(frame) / 60, selection: 2) }
        for (index, point) in points.enumerated() {
            let target = NavigationStarMotion.target(index, selection: 2, time: 0.4)
            #expect(hypot((point.x - target.x) * w, (point.y - target.y) * h) < 1)
        }
    }

    @Test func retargetingPreservesVelocityAsWellAsPosition() {
        let motion = NavigationStarMotion()
        _ = motion.sample(time: 0, selection: 0)
        _ = motion.sample(time: 0, selection: 2)
        for frame in 1...6 { _ = motion.sample(time: Double(frame) / 60, selection: 2) }
        let epsilon = 0.00001, time = 0.12
        let before = motion.sample(time: time - epsilon, selection: 2)
        let center = motion.sample(time: time, selection: 2)
        let retargeted = motion.sample(time: time, selection: 0)
        let after = motion.sample(time: time + epsilon, selection: 0)
        for index in center.indices {
            #expect(hypot(center[index].x - retargeted[index].x, center[index].y - retargeted[index].y) < 1e-8)
            let vx = (center[index].x - before[index].x) / epsilon
            let vy = (center[index].y - before[index].y) / epsilon
            let nextX = (after[index].x - retargeted[index].x) / epsilon
            let nextY = (after[index].y - retargeted[index].y) / epsilon
            #expect(hypot(nextX - vx, nextY - vy) < 0.02)
        }
    }

    @Test func frameRateAndPausedClockDoNotChangeFlightProgress() {
        func points(rate: Int) -> [CGPoint] {
            let motion = NavigationStarMotion()
            _ = motion.sample(time: 0, selection: 0)
            _ = motion.sample(time: 0, selection: 2)
            var result: [CGPoint] = []
            for frame in 1...(rate / 2) { result = motion.sample(time: Double(frame) / Double(rate), selection: 2) }
            return result
        }
        let reference = points(rate: 60)
        for rate in [12, 24, 30] {
            #expect(zip(reference, points(rate: rate)).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-8 })
        }
        let motion = NavigationStarMotion()
        _ = motion.sample(time: 0, selection: 0)
        _ = motion.sample(time: 0, selection: 2)
        let before = motion.sample(time: 0.1, selection: 2)
        for _ in 0..<20 { #expect(motion.sample(time: 0.1, selection: 2) == before) }
        #expect(motion.preferredRate(selection: 2) == NavigationStarMotion.flightRate)
    }

    @Test func textDimmingHasNoHardBrightnessEdge() {
        let left = NavigationStarMotion.textVisibility(at: CGPoint(x: (OrbitRow.centre(1) + 18.999) / w, y: 0.5))
        let right = NavigationStarMotion.textVisibility(at: CGPoint(x: (OrbitRow.centre(1) + 19.001) / w, y: 0.5))
        #expect(abs(right - left) < 0.001)
        #expect(NavigationStarMotion.textVisibility(at: CGPoint(x: 0.5, y: 0.5)) < 0.2)
        #expect(NavigationStarMotion.textVisibility(at: CGPoint(x: 0.5, y: 0.1)) == 1)
    }

    @Test func aSelectionChangeFansOutVerticallyInsteadOfTranslatingTheGroup() {
        let changed = NavigationStarMotion(), unchanged = NavigationStarMotion()
        for frame in 0...90 {
            _ = changed.sample(time: Double(frame) / 30, selection: 0)
            _ = unchanged.sample(time: Double(frame) / 30, selection: 0)
        }
        var above = 0.0, below = 0.0
        for frame in 91...115 {
            let a = changed.sample(time: Double(frame) / 30, selection: 2)
            let b = unchanged.sample(time: Double(frame) / 30, selection: 0)
            for (new, reference) in zip(a, b) {
                above = max(above, (reference.y - new.y) * h)
                below = max(below, (new.y - reference.y) * h)
            }
        }
        #expect(above > 5)
        #expect(below > 5)
    }

    @Test func midFlightRetargetingStartsFromTheVisiblePositions() {
        let motion = NavigationStarMotion()
        for frame in 0...90 { _ = motion.sample(time: Double(frame) / 30, selection: 0) }
        for frame in 91...160 {
            let time = Double(frame) / 30
            let previous = (frame / 8) % 3
            let before = motion.sample(time: time, selection: previous)
            let retargeted = motion.sample(time: time, selection: (previous + 1) % 3)
            #expect(zip(before, retargeted).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.000001 })
        }
        var settled: [CGPoint] = []
        for frame in 161...260 { settled = motion.sample(time: Double(frame) / 30, selection: 2) }
        #expect(settled.map(\.x).reduce(0, +) / Double(settled.count) > 0.78)
    }

    @Test func starsFollowSelectionAndKeepMoving() {
        let motion = NavigationStarMotion()
        var points: [CGPoint] = []
        for frame in 0...90 { points = motion.sample(time: Double(frame) / 30, selection: 0) }
        #expect(points.map(\.x).reduce(0, +) / Double(points.count) < 0.22)
        let before = points
        for frame in 91...180 { points = motion.sample(time: Double(frame) / 30, selection: 2) }
        #expect(points.map(\.x).reduce(0, +) / Double(points.count) > 0.78)
        #expect(zip(points, before).allSatisfy { $0.x > $1.x })
        let arrived = points
        for frame in 181...210 { points = motion.sample(time: Double(frame) / 30, selection: 2) }
        #expect(zip(arrived, points).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.02 })
    }

    @Test func rapidSwitchingAndSuspensionStayBounded() {
        let motion = NavigationStarMotion()
        for frame in 0...300 {
            let points = motion.sample(time: Double(frame) / 30, selection: (frame / 4) % 3)
            #expect(points.count == NavigationStarMotion.count)
            #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) })
        }
        let before = motion.sample(time: 10, selection: 0)
        let after = motion.sample(time: 400, selection: 2)
        #expect(zip(before, after).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.12 })
    }

    @Test func reducedMotionSelectsImmediatelyWithoutMovement() {
        let motion = NavigationStarMotion()
        let a = motion.sample(time: 0, selection: 1, stationary: true)
        let b = motion.sample(time: 200, selection: 1, stationary: true)
        #expect(a == b)
        #expect(motion.sample(time: 201, selection: 2, stationary: true) != a)
    }
}
