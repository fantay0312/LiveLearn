import Testing
import Foundation
@testable import AudioDomain

@Suite("Streaming resampler")
struct ResamplerTests {
    @Test("48 kHz → 16 kHz: exact 3:1 sample count per block and across blocks")
    func integerRatio() {
        var r = StreamingResampler(sourceRate: 48_000, targetRate: 16_000)
        let out = r.process([Float](repeating: 0.5, count: 4800))
        #expect(out.count == 1600)
        var total = 0
        for _ in 0..<50 { total += r.process([Float](repeating: 0.5, count: 480)).count }
        #expect(total == 50 * 160)
    }

    @Test("44.1 kHz → 16 kHz: fractional remainder carries so the long-run count is exact")
    func fractionalRatio() {
        var r = StreamingResampler(sourceRate: 44_100, targetRate: 16_000)
        var total = 0
        var input = 0
        for _ in 0..<200 {
            total += r.process([Float](repeating: 0.1, count: 441)).count
            input += 441
        }
        let expected = Double(input) * 16_000 / 44_100
        #expect(abs(Double(total) - expected) <= 1, "got \(total), expected \(expected)")
    }

    @Test("24 kHz → 16 kHz and 16 kHz → 48 kHz")
    func otherRatios() {
        var down = StreamingResampler(sourceRate: 24_000, targetRate: 16_000)
        var n = 0
        for _ in 0..<30 { n += down.process([Float](repeating: 0, count: 240)).count }
        #expect(n == 30 * 160)
        var up = StreamingResampler(sourceRate: 16_000, targetRate: 48_000)
        var m = 0
        for _ in 0..<30 { m += up.process([Float](repeating: 0, count: 160)).count }
        // Up-sampling defers the outputs that fall between the last input sample and the next
        // block's first sample (at most target/source samples); they arrive with the next block.
        #expect(30 * 480 - m <= 3 && 30 * 480 - m >= 0, "got \(m)")
        m += up.process([Float](repeating: 0, count: 160)).count
        #expect(31 * 480 - m <= 3)
    }

    @Test("A 1 kHz tone survives 48 → 16 kHz with its level, and is continuous across blocks")
    func tonePreserved() {
        var r = StreamingResampler(sourceRate: 48_000, targetRate: 16_000)
        var out: [Float] = []
        var phase = 0.0
        for _ in 0..<40 {
            var block: [Float] = []
            for _ in 0..<480 {
                block.append(Float(sin(phase)) * 0.5)
                phase += 2 * .pi * 1000 / 48_000
            }
            out.append(contentsOf: r.process(block))
        }
        // Skip the filter warm-up, then compare RMS with the ideal 0.5/√2.
        let settled = Array(out.dropFirst(200))
        let rms = (settled.map { $0 * $0 }.reduce(0, +) / Float(settled.count)).squareRoot()
        #expect(abs(rms - 0.3536) < 0.02, "rms \(rms)")
        // No block-boundary clicks: the largest step between neighbours stays below what a
        // 1 kHz tone at 16 kHz can produce (≈ 0.5·2π·1000/16000 ≈ 0.196 per sample).
        var maxStep: Float = 0
        for i in 1..<settled.count { maxStep = max(maxStep, abs(settled[i] - settled[i - 1])) }
        #expect(maxStep < 0.25, "max step \(maxStep)")
    }

    @Test("Identity rate passes the block through unchanged")
    func identity() {
        var r = StreamingResampler(sourceRate: 16_000, targetRate: 16_000)
        let input: [Float] = [0.1, 0.2, 0.3]
        #expect(r.process(input) == input)
        #expect(r.isIdentity)
    }
}

@Suite("Timeline clock corrections")
struct TimelineCorrectionTests {
    @Test("B14: a backward host time never moves the timeline back and reports no gap")
    func backwardHostTime() {
        var t = LaneTimeline(sessionAnchorNs: 0, captureEpoch: 1, sampleRate: 48_000)
        let a = t.stamp(frameCount: 4800, hostNs: 1_000_000_000)
        let b = t.stamp(frameCount: 4800, hostNs: 100_000_000)
        #expect(b.startNs == a.endNs)
        #expect(b.gap == nil)
        #expect(b.discontinuityBefore)
        #expect(b.clockCorrectedNs == 1_000_000_000)
        #expect(t.clockCorrections == 1)
        // The following block continues from the corrected anchor.
        let c = t.stamp(frameCount: 4800, hostNs: 200_000_000)
        #expect(c.startNs == b.endNs)
        #expect(!c.discontinuityBefore)
    }

    @Test("A new epoch cannot start before the previous epoch ended")
    func epochNeverBackwards() {
        var t = LaneTimeline(sessionAnchorNs: 0, captureEpoch: 1, sampleRate: 48_000)
        let a = t.stamp(frameCount: 4800, hostNs: 1_000_000_000)
        t.beginEpoch(2, sampleRate: 24_000)
        let b = t.stamp(frameCount: 240, hostNs: 500_000_000)
        #expect(b.startNs >= a.endNs)
        #expect(b.endNs - b.startNs == 10_000_000)
    }

    @Test("Forward jumps still produce a gap (unchanged behaviour)")
    func forwardGap() {
        var t = LaneTimeline(sessionAnchorNs: 0, captureEpoch: 1, sampleRate: 48_000)
        _ = t.stamp(frameCount: 480, hostNs: 0)
        let j = t.stamp(frameCount: 480, hostNs: 500_000_000)
        #expect(j.gap?.0 == 10_000_000)
        #expect(j.gap?.1 == 500_000_000)
        #expect(j.clockCorrectedNs == 0)
    }
}
