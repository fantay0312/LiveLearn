import Foundation

/// Streaming sample-rate converter for mono Float32 speech audio. Platform neutral, no
/// allocations on the hot path beyond the output array.
///
/// Design: a windowed-sinc low-pass FIR (anti-alias when downsampling, anti-image when
/// upsampling) followed by linear interpolation at the output phase. State (filter history and
/// fractional phase) carries across `process` calls so consecutive packets join without clicks,
/// and the number of output samples over time equals `input × target / source` exactly (the
/// fractional remainder is carried, never rounded away).
///
/// Quality is adequate for 16 kHz speech recognition (≈ −60 dB stop band with a Blackman
/// window). Music-grade conversion would use a polyphase design; that is not needed here.
public struct StreamingResampler: Sendable {
    public let sourceRate: Double
    public let targetRate: Double
    /// Ratio of input samples per output sample.
    private let step: Double
    private let taps: [Float]
    private var history: [Float]     // last taps.count-1 raw input samples
    private var previousFiltered: Float = 0
    private var hasPrevious = false
    /// Position of the next output sample, in input-sample units relative to the start of the
    /// block being processed. May be negative (pointing at `previousFiltered`).
    private var phase: Double = 0

    public var isIdentity: Bool { sourceRate == targetRate }

    public init(sourceRate: Double, targetRate: Double) {
        precondition(sourceRate > 0 && targetRate > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.step = sourceRate / targetRate
        if sourceRate == targetRate {
            self.taps = []
        } else {
            // Cut off a little under the Nyquist of the lower of the two rates.
            let cutoff = 0.45 * min(sourceRate, targetRate) / sourceRate  // cycles per input sample
            let tapCount = sourceRate > targetRate ? Self.tapCount(for: step) : 23
            self.taps = Self.windowedSinc(cutoff: cutoff, taps: tapCount)
        }
        self.history = [Float](repeating: 0, count: max(0, taps.count - 1))
    }

    private static func tapCount(for ratio: Double) -> Int {
        // Longer filters for steeper down-conversion; always odd for a symmetric FIR.
        let n = Int((16 * ratio).rounded()) | 1
        return min(max(n, 23), 95)
    }

    private static func windowedSinc(cutoff: Double, taps: Int) -> [Float] {
        let m = taps - 1
        var h = [Double](repeating: 0, count: taps)
        var sum = 0.0
        for i in 0..<taps {
            let x = Double(i) - Double(m) / 2
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            // Blackman window.
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(m)) + 0.08 * cos(4 * .pi * Double(i) / Double(m))
            h[i] = sinc * w
            sum += h[i]
        }
        return h.map { Float($0 / sum) }
    }

    /// Forgets filter history and phase. Call at a capture discontinuity or a new epoch.
    public mutating func reset() {
        for i in history.indices { history[i] = 0 }
        previousFiltered = 0
        hasPrevious = false
        phase = 0
    }

    /// Converts one block. Returns the output samples that can be produced without seeing the
    /// next block; the remainder is carried in `phase`.
    public mutating func process(_ input: [Float]) -> [Float] {
        if isIdentity || input.isEmpty { return input }
        let filtered = lowPass(input)
        let n = filtered.count
        var out: [Float] = []
        out.reserveCapacity(Int(Double(n) / step) + 2)
        var pos = phase
        while pos < Double(n) {
            let i = Int(pos.rounded(.down))
            let frac = Float(pos - Double(i))
            let a: Float
            if i < 0 {
                guard hasPrevious else { pos += step; continue }
                a = previousFiltered
            } else {
                a = filtered[i]
            }
            let b: Float
            if i + 1 < n {
                b = filtered[i + 1]
            } else if frac == 0 {
                b = a
            } else {
                break  // needs the first sample of the next block
            }
            out.append(a + (b - a) * frac)
            pos += step
        }
        phase = pos - Double(n)
        previousFiltered = filtered[n - 1]
        hasPrevious = true
        return out
    }

    private mutating func lowPass(_ x: [Float]) -> [Float] {
        let t = taps.count
        if t == 0 { return x }
        let hLen = t - 1
        // Work on history + x so every output sample sees a full window.
        var buf = history
        buf.append(contentsOf: x)
        var y = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var acc: Float = 0
            let base = i + hLen
            for k in 0..<t {
                acc += taps[k] * buf[base - k]
            }
            y[i] = acc
        }
        if x.count >= hLen {
            history = Array(x[(x.count - hLen)...])
        } else {
            history.removeFirst(x.count)
            history.append(contentsOf: x)
        }
        return y
    }
}
