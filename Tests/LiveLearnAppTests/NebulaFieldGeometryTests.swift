import Foundation
import Testing
@testable import LiveLearnApp
import ParticleMath

struct NebulaFieldGeometryTests {
    @Test func brightStarsAndFineDustBothMoveVisibly() {
        let size = CGSize(width: 1180, height: 760)
        let stars = (0..<290).map { index in
            let a = StellarAtmosphere.position(index: index, time: 0, size: size)
            let b = StellarAtmosphere.position(index: index, time: 2, size: size)
            return hypot(b.x - a.x, b.y - a.y)
        }
        #expect(stars.filter { $0 > 4 }.count > 260)
        let a = NebulaFieldGeometry.grains(time: 0), b = NebulaFieldGeometry.grains(time: 2)
        let dust = zip(a, b).map { hypot(($1.point.x - $0.point.x) * size.width, ($1.point.y - $0.point.y) * size.height) }
        #expect(dust.filter { $0 > 4 }.count > Int(Double(NebulaFieldGeometry.count) * 0.85))
    }

    @Test func randomCloudsCoverAnAreaWithUnevenDensity() {
        let grains = NebulaFieldGeometry.grains(time: 0)
        #expect(grains.count == NebulaFieldGeometry.count)
        var bins = Array(repeating: 0, count: 48)
        for grain in grains where (0..<1).contains(grain.point.x) && (0..<1).contains(grain.point.y) {
            bins[Int(grain.point.y * 6) * 8 + Int(grain.point.x * 8)] += 1
        }
        #expect(bins.filter { $0 > 0 }.count >= 40)
        let average = Double(bins.reduce(0, +)) / 48
        let variance = bins.map { pow(Double($0) - average, 2) }.reduce(0, +) / 48
        #expect(sqrt(variance) > average * 0.45)
    }

    @Test func localDriftIsContinuousAndDoesNotMoveAsOneSheet() {
        let a = NebulaFieldGeometry.grains(time: 0)
        let next = NebulaFieldGeometry.grains(time: 1.0 / 30)
        let b = NebulaFieldGeometry.grains(time: 8)
        #expect(zip(a, next).allSatisfy { hypot($0.point.x - $1.point.x, $0.point.y - $1.point.y) < 0.003 })
        let shifts = zip(a, b).map { CGPoint(x: $1.point.x - $0.point.x, y: $1.point.y - $0.point.y) }
        #expect(shifts.filter { $0.x > 0.005 }.count > 200)
        #expect(shifts.filter { $0.x < -0.005 }.count > 200)
        #expect(b.allSatisfy { $0.point.x.isFinite && $0.point.y.isFinite && (0...1).contains($0.opacity) })
    }
}
