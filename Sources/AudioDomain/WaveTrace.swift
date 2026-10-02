import Foundation

/// The last few seconds of one lane's smoothed level, plus a phase that advances only while
/// there is sound. The top bar draws it as a line that flows while someone speaks and lies
/// still when nobody does: the envelope scrolls in from the right, the ripple travels along
/// it, and silence leaves both exactly where they were, so nothing on screen moves on its own.
///
/// Pure value logic; the model feeds it at the level clock (30 Hz) and only publishes a trace
/// that actually changed, which a flat one never does.
public struct WaveTrace: Sendable, Equatable {
    public static let defaultLength = 64
    /// How far the ripple travels per unit of level per tick, in radians.
    public static let phaseRate: Float = 0.42
    /// The period of the drawn ripple in `phase`. The ripple is `sin(a) · 0.72 + sin(1.9a + 0.8) · 0.28`,
    /// whose two harmonics only line up again every 20π, so every wrap of a phase (here and in
    /// the drift the top bar adds) must happen on this period, or the second harmonic ticks.
    /// Move this if that ratio ever changes.
    public static let phasePeriod: Float = 20 * .pi

    public private(set) var samples: [Float]
    public private(set) var phase: Float = 0

    public init(length: Int = WaveTrace.defaultLength) {
        samples = Array(repeating: 0, count: max(2, length))
    }

    /// A trace with a given envelope, for previews and tests.
    public init(samples: [Float], phase: Float = 0) {
        self.samples = samples.count >= 2 ? samples : Array(repeating: 0, count: 2)
        self.phase = phase
    }

    /// Appends the newest level (0...1) at the right, drops the oldest at the left, and moves
    /// the ripple in proportion to how loud it is.
    public mutating func push(level: Float) {
        let l = min(max(level, 0), 1)
        samples.removeFirst()
        samples.append(l)
        if l > 0 {
            phase += l * Self.phaseRate
            let turn = Self.phasePeriod
            if phase >= turn { phase -= turn * (phase / turn).rounded(.down) }
        }
    }

    /// Nothing to draw but the baseline.
    public var isFlat: Bool { samples.allSatisfy { $0 == 0 } }

    /// The newest level.
    public var current: Float { samples.last ?? 0 }
}
