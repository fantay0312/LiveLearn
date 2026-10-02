import Foundation
import Testing
@testable import LiveLearnApp

struct MembraneGeometryTests {
    @Test func bodyStaysFiniteAndInsideItsDisplayAtAllPhases() {
        for time in [0.0, 0.7, 2.3, 5.8, 12, 90] {
            for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.25), CGPoint(x: -3, y: 4)] {
                let contour = MembraneGeometry.contour(time: time, pointer: point, influence: 1, pulse: 1)
                #expect(contour.count == MembraneGeometry.samples)
                #expect(contour.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0.02...0.98).contains($0.x) && (0.02...0.98).contains($0.y) })
            }
        }
    }

    @Test func breathingIsContinuousAndActuallyChangesTheShape() {
        let a = MembraneGeometry.contour(time: 0)
        let b = MembraneGeometry.contour(time: 1.0 / 30)
        let c = MembraneGeometry.contour(time: 2.5)
        let frameDelta = zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
        let laterDelta = zip(a, c).map { hypot($0.x - $1.x, $0.y - $1.y) }.max()!
        #expect(frameDelta < 0.01)
        #expect(laterDelta > 0.01)
    }

    @Test func pointerPullIsLocalAndBounded() {
        let point = CGPoint(x: 0.7, y: 0.5)
        let pulled = MembraneGeometry.pulled(point, pointer: CGPoint(x: 0.8, y: 0.5), influence: 1)
        #expect(pulled.x > point.x && pulled.x - point.x <= 0.035)
        #expect(MembraneGeometry.pulled(point, pointer: nil, influence: 1) == point)
        #expect(MembraneGeometry.pulled(point, pointer: CGPoint(x: Double.nan, y: 0), influence: 1) == point)
        for index in 0..<3 {
            #expect(MembraneGeometry.fold(index, time: 3, pointer: point, influence: 1).allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
    }
}
