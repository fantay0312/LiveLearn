import Testing
import Foundation
@testable import AudioDomain

private func packet(_ seq: UInt64, startMs: Int64, durationMs: Int64, rate: Double = 48_000) -> AudioPacket {
    let frames = Int(Double(durationMs) / 1000 * rate)
    return AudioPacket(laneID: "l", captureEpoch: 1, sequence: seq, sourceStartNs: startMs * 1_000_000, sourceEndNs: (startMs + durationMs) * 1_000_000, format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1), samples: OwnedAudioBuffer(mono: [Float](repeating: 0, count: frames)), discontinuityBefore: false)
}

@Suite("Bounded queue")
struct BoundedQueueTests {
    @Test("Overflow drops the oldest audio and reports a single merged gap")
    func overflowProducesGap() {
        let q = BoundedAudioQueue(capacityNs: 300_000_000)
        var gaps: [AudioGap] = []
        for i in 0..<6 {
            if let g = q.push(packet(UInt64(i), startMs: Int64(i) * 100, durationMs: 100)) { gaps.append(g) }
        }
        // 6 × 100 ms into a 300 ms queue: 3 drops, each push after the third reports one gap.
        #expect(gaps.count == 3)
        #expect(gaps.first?.reason == .queueOverflow)
        #expect(gaps.first?.startNs == 0)
        #expect(q.stats.droppedNs == 300_000_000)
        #expect(q.stats.queuedNs == 300_000_000)
        let first = q.pop()
        #expect(first?.sequence == 3)
    }

    @Test("Never drops the newest packet even if it alone exceeds capacity")
    func neverDropsNewest() {
        let q = BoundedAudioQueue(capacityNs: 50_000_000)
        #expect(q.push(packet(0, startMs: 0, durationMs: 100)) == nil)
        #expect(q.pop()?.sequence == 0)
        #expect(q.isEmpty)
    }
}

@Suite("Lane timeline")
struct TimelineTests {
    @Test("Sample projection is monotonic and continuous without host time")
    func projection() {
        var t = LaneTimeline(sessionAnchorNs: 0, captureEpoch: 1, sampleRate: 48_000)
        let a = t.stamp(frameCount: 480, hostNs: nil)
        let b = t.stamp(frameCount: 480, hostNs: nil)
        #expect(b.startNs == a.endNs)
        #expect(a.endNs - a.startNs == 10_000_000)
        #expect(!b.discontinuityBefore)
    }

    @Test("Host-time jump beyond threshold marks a discontinuity with a gap")
    func discontinuity() {
        var t = LaneTimeline(sessionAnchorNs: 1_000, captureEpoch: 1, sampleRate: 48_000)
        _ = t.stamp(frameCount: 480, hostNs: 1_000 + 100_000_000)
        _ = t.stamp(frameCount: 480, hostNs: 1_000 + 110_000_000)
        let jump = t.stamp(frameCount: 480, hostNs: 1_000 + 500_000_000)
        #expect(jump.discontinuityBefore)
        #expect(jump.gap?.0 == 120_000_000)
        #expect(jump.gap?.1 == 500_000_000)
        #expect(jump.startNs == 500_000_000)
    }

    @Test("Epoch change resets the anchor without time going backwards")
    func epochChange() {
        var t = LaneTimeline(sessionAnchorNs: 0, captureEpoch: 1, sampleRate: 48_000)
        let a = t.stamp(frameCount: 4800, hostNs: 10_000_000)
        t.beginEpoch(2, sampleRate: 44_100)
        let b = t.stamp(frameCount: 441, hostNs: 200_000_000)
        #expect(b.startNs > a.endNs)
        #expect(b.endNs - b.startNs == 10_000_000)
    }
}

@Suite("Monotonic clock")
struct ClockTests {
    @Test("Host time converts onto the same nanosecond clock as nowNs (within 2 ms)")
    func hostTimeMatchesNow() {
        let host = MonotonicClock.hostTimeToNs(MonotonicClock.hostTimeNow())
        let now = MonotonicClock.nowNs()
        #expect(abs(host - now) < 2_000_000, "host→ns \(host) vs now \(now)")
    }
}

@Suite("Level smoother")
struct LevelSmootherTests {
    @Test("Attack is faster than release")
    func attackRelease() {
        var s = LevelSmoother()
        s.feed(rms: 0.0001, nowNs: 0)
        let up = s.feed(rms: 0.3, nowNs: 60_000_000)
        #expect(up > 0.5)
        let down = s.feed(rms: 0.0001, nowNs: 120_000_000)
        #expect(down > 0.5)
        let later = s.feed(rms: 0.0001, nowNs: 2_000_000_000)
        #expect(later < 0.05)
    }
}
