import Foundation
import Testing
@testable import LiveLearnApp
import ParticleMath

struct StardustGeometryTests {
    @Test func theCloudHasAnInteriorAndStaysInsideItsStage() {
        for time in [0.0, 2, 7, 30, 120] {
            let grains = StardustGeometry.grains(time: time, pointer: CGPoint(x: 0.8, y: 0.2), influence: 1, pulse: 1, activity: 1)
            #expect(grains.count == StardustGeometry.count)
            #expect(grains.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && (0.02...0.98).contains($0.point.x) && (0.02...0.98).contains($0.point.y) })
            let center = StardustGeometry.center
            #expect(grains.filter { hypot($0.point.x - center.x, $0.point.y - center.y) < 0.2 }.count > 450)
            #expect(grains.allSatisfy { (0...1).contains($0.opacity) && $0.radius > 0 })
        }
    }

    @Test func currentsEvolveContinuouslyAndPointerPullIsLocal() {
        let original = StardustGeometry.grains(time: 0)
        let next = StardustGeometry.grains(time: 1.0 / 30)
        let later = StardustGeometry.grains(time: 4)
        #expect(zip(original, next).allSatisfy { hypot($0.point.x - $1.point.x, $0.point.y - $1.point.y) < 0.01 })
        #expect(zip(original, later).filter { hypot($0.point.x - $1.point.x, $0.point.y - $1.point.y) > 0.03 }.count > 500)
        let pulled = StardustGeometry.grains(time: 0, pointer: CGPoint(x: 0.8, y: 0.5), influence: 1)
        #expect(zip(original, pulled).allSatisfy { hypot($0.point.x - $1.point.x, $0.point.y - $1.point.y) < 0.025 })
    }
}
