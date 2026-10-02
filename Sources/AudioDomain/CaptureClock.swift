import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Monotonic host clock in nanoseconds. Wall-clock time is only metadata.
public enum MonotonicClock {
    public static func nowNs() -> Int64 {
        #if canImport(Darwin)
        return Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        #else
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        #endif
    }

    #if canImport(Darwin)
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Converts a Core Audio / mach host time to nanoseconds on the same clock as `nowNs()`.
    /// Exact 128-bit arithmetic: a truncating split would drift by up to (denom-1)/denom × 2^32 ns.
    public static func hostTimeToNs(_ hostTime: UInt64) -> Int64 {
        let tb = timebase
        if tb.numer == tb.denom { return Int64(hostTime) }
        let product = hostTime.multipliedFullWidth(by: tb.numer)
        let (quotient, _) = tb.denom.dividingFullWidth((product.high, product.low))
        return Int64(quotient)
    }

    /// Current mach host time, for tests and diagnostics.
    public static func hostTimeNow() -> UInt64 { mach_absolute_time() }
    #endif
}

/// Session-relative timeline for one lane and one capture epoch.
///
/// Prefers hardware host time when the callback provides it, and falls back to a
/// sample-index projection anchored at the first packet of the epoch. Detects
/// discontinuities by comparing host time with the sample projection.
public struct LaneTimeline: Sendable {
    public let sessionAnchorNs: Int64
    public private(set) var captureEpoch: UInt64
    public private(set) var sampleRate: Double
    private var epochAnchorNs: Int64?
    private var sampleIndex: Int64 = 0
    private var expectedNextNs: Int64?
    /// Added to every host time after a backward step, so the hardware clock is re-based once
    /// and later blocks from the same clock flow without further corrections.
    private var hostShiftNs: Int64 = 0
    /// Host-time jitter beyond this is treated as a discontinuity.
    public var discontinuityThresholdNs: Int64 = 20_000_000

    public init(sessionAnchorNs: Int64, captureEpoch: UInt64, sampleRate: Double) {
        self.sessionAnchorNs = sessionAnchorNs
        self.captureEpoch = captureEpoch
        self.sampleRate = sampleRate
    }

    public struct Stamp: Sendable, Equatable {
        public let startNs: Int64
        public let endNs: Int64
        public let discontinuityBefore: Bool
        public let gap: (Int64, Int64)?
        /// Set when the hardware clock stepped backwards and the timeline was re-anchored to keep
        /// session time monotonic. This is a clock correction, not lost audio: no gap is reported.
        public let clockCorrectedNs: Int64

        public init(startNs: Int64, endNs: Int64, discontinuityBefore: Bool, gap: (Int64, Int64)?, clockCorrectedNs: Int64 = 0) {
            self.startNs = startNs
            self.endNs = endNs
            self.discontinuityBefore = discontinuityBefore
            self.gap = gap
            self.clockCorrectedNs = clockCorrectedNs
        }

        public static func == (lhs: Stamp, rhs: Stamp) -> Bool {
            lhs.startNs == rhs.startNs && lhs.endNs == rhs.endNs && lhs.discontinuityBefore == rhs.discontinuityBefore && lhs.clockCorrectedNs == rhs.clockCorrectedNs
        }
    }

    /// Count of backward clock steps absorbed since the epoch began (diagnostics).
    public private(set) var clockCorrections = 0

    /// Begins a new epoch (device change, format change, restart). Sample index resets.
    public mutating func beginEpoch(_ epoch: UInt64, sampleRate: Double) {
        captureEpoch = epoch
        self.sampleRate = sampleRate
        epochAnchorNs = nil
        sampleIndex = 0
        // Keep `expectedNextNs`: the next epoch may not start before the previous one ended.
        clockCorrections = 0
        hostShiftNs = 0
    }

    /// Stamps a block. `hostNs` is the host-clock time of the first frame if known.
    ///
    /// Session time never runs backwards: a forward jump beyond the threshold is a real
    /// discontinuity (audio was lost, a gap is reported); a backward jump is a clock correction
    /// (device switch, host-time re-sync) and the block is placed where the projection expected
    /// it, with the correction amount recorded and no gap.
    public mutating func stamp(frameCount: Int, hostNs: Int64?) -> Stamp {
        let durationNs = Int64((Double(frameCount) / sampleRate) * 1_000_000_000)
        var startNs: Int64
        var discontinuity = false
        var gap: (Int64, Int64)? = nil
        var corrected: Int64 = 0

        if let hostNs {
            var relative = hostNs - sessionAnchorNs + hostShiftNs
            if let expected = expectedNextNs, relative < expected - discontinuityThresholdNs {
                // Backward step: never let a block start before the previous one ended. Re-base
                // the hardware clock by the same amount so this is corrected once, not per block.
                corrected = expected - relative
                hostShiftNs += corrected
                clockCorrections += 1
                relative = expected
                discontinuity = true
                epochAnchorNs = relative
                sampleIndex = 0
            }
            if epochAnchorNs == nil {
                epochAnchorNs = relative
                sampleIndex = 0
            }
            let projected = epochAnchorNs! + Int64((Double(sampleIndex) / sampleRate) * 1_000_000_000)
            let drift = relative - projected
            if corrected == 0, abs(drift) > discontinuityThresholdNs {
                discontinuity = true
                if drift > 0, let expected = expectedNextNs {
                    gap = (expected, relative)
                }
                // Re-anchor on hardware time, keep sample index continuing from here.
                epochAnchorNs = relative
                sampleIndex = 0
            }
            startNs = relative
        } else {
            if epochAnchorNs == nil {
                epochAnchorNs = MonotonicClock.nowNs() - sessionAnchorNs
                sampleIndex = 0
            }
            startNs = epochAnchorNs! + Int64((Double(sampleIndex) / sampleRate) * 1_000_000_000)
        }
        if let expected = expectedNextNs, startNs < expected - discontinuityThresholdNs {
            // Sample projection can only step back after beginEpoch; keep monotonic anyway.
            corrected = expected - startNs
            clockCorrections += 1
            startNs = expected
            epochAnchorNs = startNs
            sampleIndex = 0
            discontinuity = true
        }
        sampleIndex += Int64(frameCount)
        let endNs = startNs + durationNs
        expectedNextNs = endNs
        return Stamp(startNs: startNs, endNs: endNs, discontinuityBefore: discontinuity, gap: gap, clockCorrectedNs: corrected)
    }
}
