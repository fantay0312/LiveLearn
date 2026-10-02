import Testing
@testable import LiveLearnApp

struct StardustMotionTests {
    @Test func activationChangesSpeedWithoutJumpingOrientation() {
        let motion = StardustMotion()
        var idle = motion.sample(time: 0, targetActivity: 0.12)
        for frame in 1...90 { idle = motion.sample(time: Double(frame) / 30, targetActivity: 0.12) }
        let activated = motion.sample(time: 3, targetActivity: 1)
        #expect(activated.phase == idle.phase)
        var running = activated
        for frame in 91...150 { running = motion.sample(time: Double(frame) / 30, targetActivity: 1) }
        #expect(running.phase - activated.phase > 7)
        #expect(running.activity > 0.98)
        let beforePause = running.phase
        for frame in 151...210 { running = motion.sample(time: Double(frame) / 30, targetActivity: 0.18) }
        #expect(running.phase > beforePause)
        #expect(running.phase - beforePause < 4)
    }

    @Test func backgroundSuspensionCannotCauseAJump() {
        let motion = StardustMotion()
        _ = motion.sample(time: 0, targetActivity: 1)
        let a = motion.sample(time: 1.0 / 30, targetActivity: 1)
        let b = motion.sample(time: 900, targetActivity: 1)
        #expect(b.phase - a.phase < 0.30)
    }

    @Test func backgroundFrameRatePreservesIdleMotionSpeed() {
        func phase(rate: Int) -> Double {
            let motion = StardustMotion()
            var frame = motion.sample(time: 0, targetActivity: 0.12)
            for index in 1...rate {
                frame = motion.sample(time: Double(index) / Double(rate), targetActivity: 0.12)
            }
            return frame.phase
        }
        #expect(abs(phase(rate: 12) - phase(rate: 30)) < 0.000_001)
    }
}
