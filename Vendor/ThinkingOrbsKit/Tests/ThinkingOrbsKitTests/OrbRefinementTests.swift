import XCTest
@testable import ThinkingOrbsKit

final class OrbRefinementTests: XCTestCase {
    func testFineRingPreservesMotionParametersAndDefaultCache() {
        let original = resolvePreset(.breathing, .px64)
        let fine = resolvePreset(.breathing, .px64, ringSegments: 192)
        XCTAssertEqual(original.opts["segs"], 44)
        XCTAssertEqual(fine.opts["segs"], 192)
        XCTAssertEqual(original.speed, fine.speed)
        for key in ["lanes", "bandMul", "wobMul", "spin", "faceOn", "rBase", "rDepth"] {
            XCTAssertEqual(original.opts[key], fine.opts[key], key)
        }
        XCTAssertEqual(resolvePreset(.breathing, .px64).opts["segs"], 44)
        XCTAssertEqual(orbFrame(fine, size: 64, t: 0.8).dots.count, 2112)
    }

    func testRefinementIsBoundedAndDoesNotChangeOtherModes() {
        XCTAssertEqual(resolvePreset(.breathing, .px64, ringSegments: -1).opts["segs"], 44)
        XCTAssertEqual(resolvePreset(.breathing, .px64, ringSegments: 10000).opts["segs"], 256)
        let original = resolvePreset(.composing, .px64)
        let ignored = resolvePreset(.composing, .px64, ringSegments: 192)
        XCTAssertEqual(original.opts, ignored.opts)
    }

    func testRefinedGeometryFrameBudget() {
        let fine = resolvePreset(.breathing, .px64, ringSegments: 192)
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<400 { _ = orbFrame(fine, size: 64, t: Double(i) / 30) }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 400
        print("Refined 2112-point geometry: \(milliseconds) ms/frame; rasterization measured separately")
        XCTAssertLessThan(milliseconds, 4)
    }
}
