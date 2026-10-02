import Foundation
import ParticleMath

/// Integrate speed changes instead of multiplying absolute time when the session changes.
/// The mood (how the core shines in idle, running and paused) eases at the same rate as the
/// activity, so a start or a pause turns the light as smoothly as it turns the speed.
final class StardustMotion {
    struct Frame {
        let phase: Double
        let activity: Double
        let mood: StardustMood
    }
    private var phase = 0.0
    private var activity = 0.12
    private var mood = StardustMood.idle
    private var lastTime: Double?

    func sample(time: Double, targetActivity: Double, targetMood: StardustMood = .idle) -> Frame {
        let t = time.isFinite ? time : 0
        let elapsed = max(0, t - (lastTime ?? t))
        // Honor the normal 12 Hz background cadence; cap long suspension gaps separately.
        let dt = elapsed > 0.25 ? 1.0 / 15 : min(0.1, elapsed)
        lastTime = t
        let target = min(1, max(0, targetActivity))
        let ease = 1 - exp(-dt * 4.5)
        activity += (target - activity) * ease
        mood = mood.approaching(targetMood, by: ease)
        phase += dt * (1 + activity * 3.2)
        return Frame(phase: phase, activity: activity, mood: mood)
    }
}
