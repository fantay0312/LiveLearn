import Foundation
import Testing
@testable import LiveLearnApp

/// The gated wall clock the translation helper's rail draws from: DESIGN.md's "Time never jumps on
/// resume", for the second process. `SettingsRailClock` lives in the shared
/// `UnifiedSettingsNavigation.swift` and is constructed only by the helper, which has no test target,
/// so this is the only place its rules are pinned. The gate that opens and closes it
/// (`SettingsRailPower`, in `Vendor/Easydict/Integration/UnifiedSettingsShell.swift`) is a
/// transcription of `AmbientPower`, which the host does not test either.
struct SettingsRailClockTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func aClosedGateHoldsTimeAndAnOpenOneAdvancesIt() {
        var clock = SettingsRailClock()
        #expect(!clock.running)
        #expect(clock.time(start) == 0)
        clock.setRunning(true, at: start)
        #expect(abs(clock.time(start.addingTimeInterval(2)) - 2) < 1e-9)
        clock.setRunning(false, at: start.addingTimeInterval(2))
        // Five minutes of sleeping display cost the rail nothing.
        #expect(abs(clock.time(start.addingTimeInterval(302)) - 2) < 1e-9)
        clock.setRunning(true, at: start.addingTimeInterval(302))
        #expect(abs(clock.time(start.addingTimeInterval(302)) - 2) < 1e-9)
        #expect(abs(clock.time(start.addingTimeInterval(303)) - 3) < 1e-9)
    }

    @Test func repeatedCallsNeitherRestartNorRewindTheRun() {
        var clock = SettingsRailClock()
        clock.setRunning(true, at: start)
        clock.setRunning(true, at: start.addingTimeInterval(10))
        #expect(abs(clock.time(start.addingTimeInterval(10)) - 10) < 1e-9)
        clock.setRunning(false, at: start.addingTimeInterval(10))
        clock.setRunning(false, at: start.addingTimeInterval(20))
        #expect(abs(clock.time(start.addingTimeInterval(20)) - 10) < 1e-9)
        #expect(!clock.running)
    }

    /// The clock and `SettingsRailMotion` together, which is what the helper's rail does every frame:
    /// a sleep of any length moves no point and keeps the twinkle phase, where folding the gate into
    /// `stationary` would snap the cluster to its time-0 positions and phase 0.
    @Test func aSleepingDisplayMovesNoPointAndKeepsTheTwinklePhase() {
        var clock = SettingsRailClock()
        let motion = SettingsRailMotion()
        clock.setRunning(true, at: start)
        var points: [CGPoint] = []
        for frame in 0...45 {
            let now = start.addingTimeInterval(Double(frame) / 15)
            points = motion.sample(time: clock.time(now), selection: 9, stationary: false)
        }
        let sleepInstant = start.addingTimeInterval(3)
        let held = clock.time(sleepInstant)
        clock.setRunning(false, at: sleepInstant)
        let wake = sleepInstant.addingTimeInterval(1800)
        #expect(clock.time(wake) == held)
        clock.setRunning(true, at: wake)
        let resumed = motion.sample(time: clock.time(wake), selection: 9, stationary: false)
        #expect(zip(points, resumed).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-9 })
        // The static-render path is the other behaviour, and still is.
        let snapped = motion.sample(time: clock.time(wake), selection: 9, stationary: true)
        #expect(snapped == (0..<SettingsRailMotion.count).map { SettingsRailMotion.target($0, selection: 9, time: 0) })
    }
}
