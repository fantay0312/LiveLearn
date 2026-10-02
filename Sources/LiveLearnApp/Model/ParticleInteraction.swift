import Foundation
import CoreGraphics
import Observation

@MainActor @Observable
final class ParticleInteraction {
    struct Pulse: Identifiable, Sendable {
        let id: Int
        let point: CGPoint
        let time: Double
    }
    struct Sample: Sendable {
        var point: CGPoint
        var velocity: CGSize
        var strength: Double
        var dragging: Bool
        var pulses: [Pulse]
    }

    // The canvases that sample the pointer already redraw on their own clocks, so the pointer
    // publishes nothing: an observed revision counter here made every mouse move re-evaluate
    // the dust and the core a second time between clock ticks. Only the hero frame is observed.
    private(set) var heroFrame = CGRect.zero
    @ObservationIgnored private var from = CGPoint.zero
    @ObservationIgnored private var target = CGPoint.zero
    @ObservationIgnored private var fromStrength = 0.0
    @ObservationIgnored private var targetStrength = 0.0
    @ObservationIgnored private var velocity = CGSize.zero
    @ObservationIgnored private var changedAt = 0.0
    @ObservationIgnored private var previousInput: CGPoint?
    @ObservationIgnored private var pressed = false
    @ObservationIgnored private var pulses: [Pulse] = []
    @ObservationIgnored private var nextID = 0

    func move(to point: CGPoint, dragging: Bool = false, at time: Double = Date.timeIntervalSinceReferenceDate) {
        guard point.x.isFinite && point.y.isFinite else { return }
        let current = sample(at: time)
        from = current.strength > 0.001 ? current.point : point
        target = point
        fromStrength = current.strength
        targetStrength = 1
        if let previousInput {
            velocity = CGSize(width: min(30, max(-30, (point.x - previousInput.x) * 0.6)),
                              height: min(30, max(-30, (point.y - previousInput.y) * 0.6)))
        }
        previousInput = point
        pressed = dragging
        changedAt = time
    }

    func leave(at time: Double = Date.timeIntervalSinceReferenceDate) {
        let current = sample(at: time)
        from = current.point
        target = current.point
        fromStrength = current.strength
        targetStrength = 0
        velocity = .zero
        previousInput = nil
        pressed = false
        changedAt = time
    }

    func pulse(at point: CGPoint, time: Double = Date.timeIntervalSinceReferenceDate) {
        guard point.x.isFinite && point.y.isFinite else { return }
        pulses = pulses.filter { time - $0.time < 1.2 }
        nextID &+= 1
        pulses.append(Pulse(id: nextID, point: point, time: time))
        if pulses.count > 4 { pulses.removeFirst(pulses.count - 4) }
    }

    func setHeroFrame(_ frame: CGRect) {
        if heroFrame != frame { heroFrame = frame }
    }

    func sample(at time: Double = Date.timeIntervalSinceReferenceDate) -> Sample {
        let elapsed = max(0, time - changedAt)
        let easing = 1 - exp(-elapsed / 0.10)
        let strength = fromStrength + (targetStrength - fromStrength) * easing
        return Sample(point: CGPoint(x: from.x + (target.x - from.x) * easing,
                                     y: from.y + (target.y - from.y) * easing),
                      velocity: CGSize(width: velocity.width * exp(-elapsed / 0.24), height: velocity.height * exp(-elapsed / 0.24)),
                      strength: strength, dragging: pressed,
                      pulses: pulses.filter { time - $0.time >= 0 && time - $0.time < 1.2 })
    }

    nonisolated static func displacement(at point: CGPoint, sample: Sample, time: Double) -> CGSize {
        let dx = point.x - sample.point.x, dy = point.y - sample.point.y
        var x = 0.0, y = 0.0
        // The pointer's field is a Gaussian of width 105pt: past 330pt it moves a grain by less
        // than a thousandth of a point, so those grains skip the exponential altogether.
        if sample.strength > 0, abs(dx) < 330, abs(dy) < 330 {
            let distance = max(1, (dx * dx + dy * dy).squareRoot())
            let scaled = distance / 105
            let influence = exp(-(scaled * scaled)) * sample.strength
            let force = (sample.dragging ? 34.0 : 23.0) * influence
            x = dx / distance * force + sample.velocity.width * influence * 0.35
            y = dy / distance * force + sample.velocity.height * influence * 0.35
        }
        for pulse in sample.pulses {
            let progress = (time - pulse.time) / 1.2
            guard progress >= 0 && progress < 1 else { continue }
            let px = point.x - pulse.point.x, py = point.y - pulse.point.y
            let radius = max(1, (px * px + py * py).squareRoot())
            // The ring is 30pt wide: four widths out it has no measurable effect.
            let offset = (radius - progress * 270) / 30
            guard abs(offset) < 4 else { continue }
            let wave = exp(-(offset * offset)) * 22 * (1 - progress)
            x += px / radius * wave
            y += py / radius * wave
        }
        return CGSize(width: min(60, max(-60, x)), height: min(60, max(-60, y)))
    }
}
