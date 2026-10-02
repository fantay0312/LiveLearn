import Foundation
import Testing
@testable import LiveLearnApp

/// The settings sidebar's seven-star rail: its fixed y-table, flight timing, gutter bounds
/// and the same continuity guarantees as Home's navigation stars.
struct SettingsRailMotionTests {
    private let expectedCentres: [CGFloat] = [16, 48, 80, 148, 180, 212, 280, 312, 380, 412, 444, 512]

    @Test func railTableMatchesTheSidebarGeometry() {
        #expect(LiveLearnSettingsPage.pages(in: .developer).map { LiveLearnSettingsPage.railCenterY($0) } == expectedCentres)
        var y: CGFloat = 0
        var walked: [CGFloat] = []
        for page in LiveLearnSettingsPage.pages(in: .developer) {
            if page.group != nil { y += 36 }
            walked.append(y + 16)
            y += 32
        }
        #expect(walked == expectedCentres)
        #expect(y == LiveLearnSettingsPage.railListHeight)
    }

    @Test func everyPointHasLandedWithinHalfASecond() {
        #expect(SettingsRailMotion.seeds.count == SettingsRailMotion.count)
        #expect(SettingsRailMotion.depths.count == SettingsRailMotion.count)
        for index in 0..<SettingsRailMotion.count {
            #expect(SettingsRailMotion.delay(index) + SettingsRailMotion.duration(index) <= 0.50)
        }
        // The bright star leaves first.
        #expect(SettingsRailMotion.delay(0) == 0)
    }

    /// The clock policy is one table read by both processes (`SettingsView.HostSettingsRail`
    /// and the helper's `EmbeddedSettingsRail`); it used to be two hand-written pairs of
    /// numbers. The fast window must outlast the slowest point, or a flight would finish at
    /// the resting rate.
    @Test func theFlightWindowOutlastsTheSlowestPointAtTheFastRate() {
        let longest = (0..<SettingsRailMotion.count)
            .map { SettingsRailMotion.delay($0) + SettingsRailMotion.duration($0) }.max() ?? 0
        // Point 4 leaves last (delay 0.10) at duration 0.37; the 0.10 + 0.40 pairing the
        // reconciliation bounds never actually occurs.
        #expect(abs(longest - 0.47) < 1e-9)
        #expect(longest <= 0.50)
        #expect(SettingsRailMotion.flightWindow >= longest)
        #expect(SettingsRailMotion.flightRate == 30)
        #expect(SettingsRailMotion.restRate == 15)
        #expect(SettingsRailMotion.flightRate > SettingsRailMotion.restRate)
        // The arrival blend also lands inside the window, so nothing visible is interpolated
        // at 15 Hz after a selection change.
        #expect(SettingsRailMotion.flightWindow >= longest + SettingsRailMotion.blend)
    }

    @Test func restingTargetsStayInsideTheGutter() {
        for selection in 0..<LiveLearnSettingsPage.allCases.count {
            for index in 0..<SettingsRailMotion.count {
                for step in 0..<200 {
                    let point = SettingsRailMotion.target(index, selection: selection, time: Double(step) * 0.37)
                    #expect((6...24).contains(point.x))
                    #expect(abs(point.y - LiveLearnSettingsPage.railCenterY(LiveLearnSettingsPage.allCases[selection])) <= 16.01)
                }
            }
        }
    }

    @Test func rapidSwitchingStaysBoundedAndFinite() {
        let motion = SettingsRailMotion()
        let pages = LiveLearnSettingsPage.allCases.count
        for frame in 0...300 {
            let points = motion.sample(time: Double(frame) / 30, selection: (frame / 4) % pages)
            #expect(points.count == SettingsRailMotion.count)
            #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (6...24).contains($0.x) && (-0.01...(LiveLearnSettingsPage.railListHeight + 0.01)).contains($0.y) })
        }
    }

    @Test func stationarySamplingIsTheTimeZeroClusterAndTimeIndependent() {
        let motion = SettingsRailMotion()
        let a = motion.sample(time: 0, selection: 3, stationary: true)
        let b = motion.sample(time: 250, selection: 3, stationary: true)
        #expect(a == b)
        #expect(a == (0..<SettingsRailMotion.count).map { SettingsRailMotion.target($0, selection: 3, time: 0) })
        #expect(motion.sample(time: 251, selection: 4, stationary: true) != a)
    }

    @Test func midFlightRetargetingStartsFromTheVisiblePositions() {
        let motion = SettingsRailMotion()
        for frame in 0...60 { _ = motion.sample(time: Double(frame) / 30, selection: 0) }
        for frame in 61...130 {
            let time = Double(frame) / 30
            let previous = (frame / 6) % 4
            let before = motion.sample(time: time, selection: previous)
            let retargeted = motion.sample(time: time, selection: (previous + 1) % 4)
            #expect(zip(before, retargeted).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.000001 })
        }
    }

    @Test func theClusterFollowsTheSelectionAndKeepsDrifting() {
        let motion = SettingsRailMotion()
        var points: [CGPoint] = []
        for frame in 0...30 { points = motion.sample(time: Double(frame) / 30, selection: 0) }
        let sourcesY = LiveLearnSettingsPage.railCenterY(.sources)
        #expect(points.allSatisfy { abs($0.y - sourcesY) <= 16.5 })
        // 音源与设备 → 网页翻译 is the longest flight (428 pt); 1.6 s later everything has landed
        // and blended into the drift.
        for frame in 31...80 { points = motion.sample(time: Double(frame) / 30, selection: 10) }
        let targetY = LiveLearnSettingsPage.railCenterY(.browserExtension)
        #expect(points.allSatisfy { abs($0.y - targetY) <= 16.5 })
        let arrived = points
        for frame in 81...140 { points = motion.sample(time: Double(frame) / 30, selection: 10) }
        #expect(zip(arrived, points).contains { hypot($0.x - $1.x, $0.y - $1.y) > 0.5 })
    }

    @Test func aLongSuspensionMovesNoPointMoreThanAFrame() {
        let motion = SettingsRailMotion()
        for frame in 0...60 { _ = motion.sample(time: Double(frame) / 30, selection: 2) }
        let before = motion.sample(time: 61.0 / 30, selection: 2)
        let after = motion.sample(time: 400, selection: 2)
        #expect(zip(before, after).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1 })
    }
}
