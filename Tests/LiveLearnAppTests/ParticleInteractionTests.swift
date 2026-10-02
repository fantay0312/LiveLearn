import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct ParticleInteractionTests {
    @Test func pointerInterpolatesAndSettlesAfterLeaving() {
        let input = ParticleInteraction()
        input.move(to: CGPoint(x: 100, y: 100), at: 0)
        input.move(to: CGPoint(x: 200, y: 100), at: 0.2)
        let inFlight = input.sample(at: 0.25)
        #expect(inFlight.point.x > 100 && inFlight.point.x < 200)
        input.leave(at: 0.3)
        #expect(input.sample(at: 1.5).strength < 0.001)
        #expect(input.sample(at: 1.5).velocity == .zero)
    }

    @Test func pulsesAreBoundedAndExpire() {
        let input = ParticleInteraction()
        for i in 0..<12 { input.pulse(at: CGPoint(x: i, y: i), time: Double(i) * 0.01) }
        #expect(input.sample(at: 0.2).pulses.count == 4)
        #expect(input.sample(at: 2).pulses.isEmpty)
    }

    @Test func forcesRemainFiniteAndLocal() {
        let input = ParticleInteraction()
        input.move(to: CGPoint(x: 100, y: 100), dragging: true, at: 0)
        input.pulse(at: CGPoint(x: 100, y: 100), time: 0)
        let sample = input.sample(at: 0.2)
        let near = ParticleInteraction.displacement(at: CGPoint(x: 140, y: 100), sample: sample, time: 0.2)
        let far = ParticleInteraction.displacement(at: CGPoint(x: 900, y: 100), sample: sample, time: 0.2)
        #expect(near.width.isFinite && abs(near.width) <= 60)
        #expect(abs(far.width) < abs(near.width))
        input.move(to: CGPoint(x: Double.nan, y: 0), at: 0.3)
        #expect(input.sample(at: 0.4).point.x.isFinite)
    }

    @Test func inputSurfaceCannotTakeButtonHitTests() {
        _ = NSApplication.shared
        let view = ParticleInputSurface.TrackingView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        #expect(view.hitTest(CGPoint(x: 300, y: 250)) == nil)
        view.detach()
    }
}
