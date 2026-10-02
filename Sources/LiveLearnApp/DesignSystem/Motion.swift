import SwiftUI
import AppKit
import QuartzCore

/// Design language §6. Every duration collapses to zero under Reduce Motion.
///
/// One curve for everything that enters: a fast start that reads as an immediate answer to the
/// press, then a long settle (`0.32, 0.72, 0, 1`). Exits are shorter and accelerate away; the
/// eye has already moved on. The primary session control additionally owns its requested
/// short press scale and ripple; reading-surface transitions stay restrained.
enum LLMotion {
    /// The enter curve, at the given length. 180ms for a sentence or a control, 200ms for a
    /// sheet, 240ms for a page.
    static func enter(_ reduce: Bool, _ duration: Double = 0.2) -> Animation? {
        reduce ? nil : .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }
    /// The exit: the same curve, about a third shorter than the enter it pairs with (§6 names
    /// only ease-out, so nothing here eases in).
    static func exit(_ reduce: Bool, _ duration: Double = 0.12) -> Animation? { enter(reduce, duration) }
    static func arrive(_ reduce: Bool) -> Animation? { enter(reduce, 0.18) }
    static func settle(_ reduce: Bool) -> Animation? { reduce ? nil : .easeInOut(duration: 0.24) }
    static func finalize(_ reduce: Bool) -> Animation? { enter(reduce, 0.40) }
    static func status(_ reduce: Bool) -> Animation? { enter(reduce, 0.15) }
    static func level(_ reduce: Bool) -> Animation? { reduce ? nil : .linear(duration: 0.08) }
    /// Hover and press on controls: quick enough to feel attached to the pointer.
    static func hover(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.12) }
    static func press(_ reduce: Bool, down: Bool) -> Animation? {
        reduce ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: down ? 0.10 : 0.20)
    }
    /// A switch or a segment moving to its other state.
    static func toggle(_ reduce: Bool) -> Animation? { enter(reduce, 0.18) }

    /// §6 "新句子出现": opacity 0→1 and a 4pt rise on the way in; nothing on the way out (old
    /// rows never move). Under Reduce Motion the transition still applies but with no animation
    /// in the transaction, so it snaps.
    static var arriveTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .identity)
    }

    /// Something joining a row of others (a fact, a word, a button): it fades in, and leaves at
    /// once, so its neighbours never share the row with a ghost of it.
    static var appear: AnyTransition { .asymmetric(insertion: .opacity, removal: .identity) }

    /// A page or a whole column taking the place of another: the new one rises 6pt into place,
    /// the old one fades a little faster underneath. Both are opacity and offset only; under
    /// Reduce Motion both snap.
    static func pageTransition(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity.animation(exit(false, 0.12)))
    }

    /// A mark replaced in place inside a fixed slot (the transport marks): crossfade, no movement.
    static var fade: AnyTransition { .opacity }

    /// The same curve for AppKit windows (the overlay, the paper menu sheet). Built per call:
    /// `CAMediaTimingFunction` is not Sendable, and the two callers are on the main actor anyway.
    @MainActor static var enterTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1) }
    @MainActor static var exitTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1) }
    /// AppKit's view of the system setting, for the two windows that animate outside SwiftUI.
    @MainActor static var systemReducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Rises into place once, when it first appears: opacity 0→1 and 6pt up, after `index × step`.
/// For the two beats of a page that is arriving (the opening line, then the rest), so it lands
/// rather than switches on. Reduce Motion and offscreen renders show the resting state at once.
struct RiseIn: ViewModifier {
    var index: Int = 0
    var step: Double = 0.08
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender

    func body(content: Content) -> some View {
        let settled = shown || reduceMotion || staticRender
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                if reduceMotion || staticRender {
                    shown = true
                } else {
                    withAnimation(LLMotion.enter(false, 0.28)?.delay(Double(index) * step)) { shown = true }
                }
            }
    }
}

extension View {
    /// See `RiseIn`.
    func riseIn(_ index: Int = 0, step: Double = 0.06) -> some View { modifier(RiseIn(index: index, step: step)) }
}

/// The breath line: a thin line whose length and opacity follow the smoothed audio level.
/// It is the only continuously moving element in the product. The length is a render-time
/// scale of a full-width capsule, so a level tick never triggers a layout pass.
///
/// Two weights: `.page` (1pt, ink, ceiling 0.6) sits on paper under the reading column and in
/// the inspector, where a heavier line read as a progress bar; `.overlay` (1.5pt, ceiling 0.9)
/// sits over video and needs the extra presence.
struct BreathLine: View {
    enum Weight {
        case page, overlay

        var thickness: CGFloat { self == .page ? 1 : 1.5 }
        var trackOpacity: Double { self == .page ? 0.0 : 0.12 }
        var floor: Double { self == .page ? 0.18 : 0.35 }
        var ceiling: Double { self == .page ? 0.60 : 0.90 }
        var idle: Double { self == .page ? 0.10 : 0.18 }
    }

    var level: Float          // 0...1, already smoothed
    var color: Color
    var active: Bool = true
    var weight: Weight = .page
    /// Faint full-width track behind the moving segment; the page weight draws it from the
    /// theme so the idle line is a real hairline rather than a tinted ink.
    var track: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let l = CGFloat(min(max(level, 0), 1))
        let w = weight
        ZStack(alignment: .leading) {
            if let track {
                Capsule().fill(track)
            } else if w.trackOpacity > 0 {
                Capsule().fill(color.opacity(w.trackOpacity))
            }
            // Opacity as a layer property, not a re-resolved fill style: the per-tick change is
            // two animatable scalars (scale, opacity) and nothing else.
            Capsule()
                .fill(color)
                .opacity(active ? w.floor + (w.ceiling - w.floor) * l : w.idle)
                .scaleEffect(x: active ? 0.22 + 0.78 * l : 0.22, y: 1, anchor: .leading)
                .animation(LLMotion.level(reduceMotion), value: level)
        }
        .frame(height: w.thickness)
        .accessibilityHidden(true)
    }
}

/// A breath line that reads its own lane's level from the model. Keeping the read in a leaf
/// means a level tick re-evaluates this 1pt view and nothing around it.
struct LaneBreathLine: View {
    let laneID: String
    var color: Color
    var active: Bool = true
    var weight: BreathLine.Weight = .page
    var track: Color? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        BreathLine(level: model.level(for: laneID), color: color, active: active, weight: weight, track: track)
    }
}

/// Session clock as a leaf: the one-per-second change stays inside this Text.
struct SessionClock: View {
    var font: Font = LLFont.timestamp
    var color: Color
    var suffix: String = ""
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(StatusCopy.clock(model.elapsedNs) + suffix)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// 6pt solid dot. Breathes slowly only while running with no audio; otherwise static. No glow.
///
/// The breathing dot is its own view that exists only in the `waiting` mode: a `repeatForever`
/// animation is torn down with the view, whereas re-assigning the animated value in place left
/// the repeat timer running after the session ended (measured: ~9% CPU in the completed state).
struct LiveDot: View {
    enum Mode { case hidden, live, waiting, paused }
    var mode: Mode
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if mode == .waiting && !reduceMotion {
                BreathingDot(color: color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(staticOpacity)
            }
        }
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
    }

    /// Paused draws nothing: a half-lit "此刻" mark would mean neither now nor off, and while
    /// paused the one accent in the bar is the resume triangle (§5.1). The 6pt frame stays.
    private var staticOpacity: Double {
        switch mode {
        case .hidden, .paused: return 0
        case .live: return 1
        case .waiting: return 0.7   // Reduce Motion: fixed mid-opacity
        }
    }

    private struct BreathingDot: View {
        var color: Color
        @State private var phase = false

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(phase ? 1.0 : 0.45)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                        phase = true
                    }
                }
        }
    }
}

/// Text that changes in place (§6 状态文案切换): the old string leaves at once and the new one
/// fades in over 150ms. One line unless the caller allows more (`lineLimit`: the top bar's
/// status sentence may take two); it never wraps the bar it sits in. The ZStack keeps the two
/// from ever being laid out side by side, and its alignment keeps the edge the bar anchors on
/// (the right end of a status cluster) where it was — a wrapped line keeps that edge too.
struct CrossfadeText: View {
    var text: String
    var font: Font
    var color: Color
    var alignment: Alignment = .trailing
    var lineLimit = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: alignment) {
            Text(text)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .multilineTextAlignment(textAlignment)
                .id(text)
                .transition(LLMotion.appear)
        }
        .animation(LLMotion.status(reduceMotion), value: text)
    }

    private var textAlignment: TextAlignment {
        switch alignment.horizontal {
        case .leading: return .leading
        case .trailing: return .trailing
        default: return .center
        }
    }
}
