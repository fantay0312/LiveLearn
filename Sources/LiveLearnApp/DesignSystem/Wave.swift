import SwiftUI
import AudioDomain

/// The sound line on the horizon (§6, 0.3): one line per lane that is always a wave.
///
/// At rest it is a low, even ripple a couple of points high, so the bar reads as sound waiting
/// rather than as a rule. While the lane listens the ripple drifts slowly. When something is
/// heard, the envelope (the last two seconds of level, scrolling in from the right) lifts the
/// ripple towards the full row height and the ripple travels with the sound. Two strands, the
/// second lighter and slightly detuned, so it reads as water rather than a signal generator.
/// Monochrome ink, no glow; the line rises out of the ground and sinks back into it over its
/// last 16 pt at either end (`WaveLine.endFade`), like every rule in the app, instead of
/// starting and stopping on a cut.
struct WaveShape: Shape {
    var samples: [Float]
    var phase: Float
    /// Amplitude at rest, in points; the wave never lies flatter than this.
    var floor: CGFloat
    /// Full ripples across the width at full level.
    var cycles: Float = 3.2
    /// Scales the amplitude; the echo strand sits lower than the main one.
    var gain: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let n = samples.count
        guard n >= 2, rect.width > 0 else { return path }
        let mid = rect.midY
        let full = max(floor, rect.height / 2 - 1)
        var points: [CGPoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let e = CGFloat(min(max(samples[i], 0), 1))
            // A main ripple and a quieter faster one riding on it; their sum never exceeds 1.
            let a = Float.pi * 2 * t * cycles + phase
            let ripple = sin(a) * 0.72 + sin(a * 1.9 + 0.8) * 0.28
            let amplitude = (floor + (full - floor) * e) * gain
            points.append(CGPoint(x: rect.minX + CGFloat(t) * rect.width, y: mid + CGFloat(ripple) * amplitude))
        }
        // Catmull-Rom through the samples, so the line stays smooth between ticks.
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, n - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// What the line is allowed to do. `still`: the resting ripple, frozen (before a session,
/// paused, finished, or a lane that stopped). `listening`: the ripple drifts on its own and
/// the envelope rides on it. Motion therefore means exactly "this lane is being listened to".
enum WaveMotion: Equatable {
    case still, listening
}

/// Two strands of one lane's wave. The drift is view-local time (`TimelineView`), so a silent
/// lane never publishes anything from the model; only sound changes the trace.
///
/// The phase is continuous across every change of state: the ripple starts drifting from
/// exactly where it rested, and rests exactly where it was when the lane paused or stopped
/// (the drift of each listening spell is carried over). The resting ripple and the moving one
/// crossfade over 240ms when the state changes, so a wave never collapses in one frame.
struct WaveLine: View {
    var trace: WaveTrace
    var color: Color
    var echo: Color
    var motion: WaveMotion
    var height: CGFloat = 16
    /// Phase offset per lane, so two resting rows are not the same curve twice.
    var seed: Float = 0
    var previewReducedMotion = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }
    @Environment(\.staticRender) private var staticRender
    /// The settings modal covers the bar: the drift holds where it is (and is carried over, like
    /// a pause) so the blurred window underneath is not re-rendered thirty times a second.
    @Environment(\.ambientMotionPaused) private var modalPaused
    /// The modal, a locked session or a sleeping display: nothing to drift for.
    private var ambientPaused: Bool { modalPaused || !AmbientPower.shared.screenAvailable }
    /// When the current listening spell began; nil while resting.
    @State private var listenStart: Date?
    /// Drift accumulated by earlier listening spells, so the rest position is where it stopped.
    @State private var driftCarried: Float = 0
    @State private var reducedPhase: Float?

    /// Radians per second the resting ripple drifts while listening.
    static let driftRate: Float = 0.9
    /// Length of the fade at each end of the line.
    static let endFade: CGFloat = LLMetrics.space(4)
    /// Seconds per full period of the ripple (20π: the two harmonics' common period), so a wrap
    /// of the elapsed drift is invisible.
    private static let cycle = Double(WaveTrace.phasePeriod / driftRate)

    var body: some View {
        // The width is read once per layout, outside the clock, and turned into the ends'
        // fade in the strokes' own colour: no mask, so a drifting frame costs no extra pass.
        GeometryReader { proxy in
            let fade = Self.fadeStops(width: proxy.size.width)
            ZStack {
                switch motion {
                case .listening where reduceMotion:
                    // Reduce Motion: the height says how loud it is; nothing travels.
                    strands(samples: Array(repeating: trace.current, count: trace.samples.count), phase: reducedPhase ?? seed,
                            level: trace.current, fade: fade)
                case .listening where staticRender:
                    strands(samples: trace.samples, phase: restingPhase, level: trace.current, fade: fade)
                case .listening:
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: ambientPaused)) { context in
                        strands(samples: trace.samples, phase: restingPhase + drift(at: context.date), level: trace.current, fade: fade)
                    }
                    .transition(.opacity)
                case .still:
                    strands(samples: Array(repeating: 0, count: trace.samples.count), phase: reduceMotion ? (reducedPhase ?? seed) : restingPhase,
                            level: 0, fade: fade)
                        .transition(.opacity)
                }
            }
        }
        .animation(LLMotion.settle(reduceMotion), value: motion)
        .frame(height: height)
        .clipped()
        .onAppear { if motion == .listening { listenStart = Date() } }
        .onChange(of: motion) { old, new in
            if new == .listening {
                listenStart = Date()
            } else if old == .listening, let start = listenStart {
                // Only drift that was drawn is carried: under Reduce Motion (or offscreen) the
                // ripple held still, so the rest position is exactly what was on screen.
                if drifts {
                    driftCarried = (driftCarried + Float(Date().timeIntervalSince(start)) * Self.driftRate)
                        .truncatingRemainder(dividingBy: WaveTrace.phasePeriod)
                }
                listenStart = nil
            }
        }
        // Reduce Motion switched off mid-spell: drift starts from the phase on screen now.
        .onChange(of: reduceMotion) { _, reduce in
            if reduce { reducedPhase = restingPhase + drift(at: Date()) }
            if !reduce, motion == .listening { listenStart = Date() }
        }
        // Covered by the modal: bank the drift drawn so far and restart the spell when it
        // returns, so the ripple resumes from the frame it held instead of jumping ahead.
        .onChange(of: ambientPaused) { _, paused in
            guard motion == .listening, drifts else { return }
            if paused, let start = listenStart {
                driftCarried = (driftCarried + Float(Date().timeIntervalSince(start)) * Self.driftRate)
                    .truncatingRemainder(dividingBy: WaveTrace.phasePeriod)
                listenStart = nil
            } else if !paused, listenStart == nil {
                listenStart = Date()
            }
        }
        .accessibilityHidden(true)
    }

    /// Drift is drawn only in the TimelineView branch.
    private var drifts: Bool { !reduceMotion && !staticRender }

    /// Where the ripple rests: the lane's seed, what sound has pushed it (`trace.phase`), and
    /// the drift of every earlier spell.
    private var restingPhase: Float { seed + trace.phase + driftCarried }

    /// Drift since this spell began, wrapped on the ripple's full period so the wrap itself is
    /// invisible.
    private func drift(at date: Date) -> Float {
        guard let listenStart else { return 0 }
        let elapsed = date.timeIntervalSince(listenStart).truncatingRemainder(dividingBy: Self.cycle)
        return Float(elapsed) * Self.driftRate
    }

    /// Resting amplitude: about 2.5pt on a single row, a little over 2pt when two rows share the bar.
    private var floor: CGFloat { min(2.5, height * 0.14) }

    /// Where the line is fully drawn, as fractions of its width: the ends fade in and out over
    /// `endFade`, or over half each when the line is shorter than two fades.
    private static func fadeStops(width: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let f = min(0.5, endFade / max(width, 1))
        return (f, 1 - f)
    }

    /// `color` across the line, clear at both ends; relative to the shape's frame (the view).
    private static func faded(_ color: Color, _ fade: (start: CGFloat, end: CGFloat)) -> LinearGradient {
        LinearGradient(stops: [.init(color: color.opacity(0), location: 0), .init(color: color, location: fade.start),
                               .init(color: color, location: fade.end), .init(color: color.opacity(0), location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }

    private func strands(samples: [Float], phase: Float, level: Float, fade: (start: CGFloat, end: CGFloat)) -> some View {
        let l = Double(level)
        return ZStack {
            WaveShape(samples: samples, phase: phase + 1.1, floor: floor, cycles: 3.2 * 1.25, gain: 0.8)
                .stroke(Self.faded(echo, fade), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                .opacity(0.35 + 0.25 * l)
            WaveShape(samples: samples, phase: phase, floor: floor)
                .stroke(Self.faded(color, fade), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .opacity(0.7 + 0.3 * l)
        }
    }
}

/// A wave that reads its own lane's trace from the model. A leaf, like `LaneBreathLine`: a
/// level tick re-evaluates this view and nothing around it. A lane the model has no trace for
/// (the draft rows before a session) draws the resting ripple.
struct LaneWave: View {
    let laneID: String
    var color: Color
    var echo: Color
    var motion: WaveMotion
    var height: CGFloat = 16
    var seed: Float = 0
    @Environment(AppModel.self) private var model

    var body: some View {
        WaveLine(trace: model.wave(for: laneID), color: color, echo: echo, motion: motion, height: height, seed: seed)
    }
}
