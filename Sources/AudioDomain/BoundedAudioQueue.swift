import Foundation
import Synchronization

/// Bounded by audio duration, not by packet count. The real-time producer only locks,
/// copies a reference, and updates counters. Overflow drops the oldest audio and reports it
/// as a gap so the timeline never pretends the dropped interval did not happen.
public final class BoundedAudioQueue: Sendable {
    public struct Stats: Sendable, Equatable {
        public var queuedNs: Int64
        public var droppedNs: Int64
        public var pushed: UInt64
        public var popped: UInt64
        public init(queuedNs: Int64 = 0, droppedNs: Int64 = 0, pushed: UInt64 = 0, popped: UInt64 = 0) {
            self.queuedNs = queuedNs
            self.droppedNs = droppedNs
            self.pushed = pushed
            self.popped = popped
        }
    }

    private struct State {
        var packets: [AudioPacket] = []
        var head = 0
        var stats = Stats()
    }

    public let capacityNs: Int64
    private let state: Mutex<State>

    public init(capacityNs: Int64 = 2_000_000_000) {
        self.capacityNs = capacityNs
        self.state = Mutex(State())
    }

    /// Returns the gap created by dropping old packets, if any.
    @discardableResult
    public func push(_ packet: AudioPacket) -> AudioGap? {
        state.withLock { s in
            s.packets.append(packet)
            s.stats.pushed += 1
            s.stats.queuedNs += packet.durationNs
            var gap: AudioGap? = nil
            while s.stats.queuedNs > capacityNs, s.head < s.packets.count - 1 {
                let dropped = s.packets[s.head]
                s.head += 1
                s.stats.queuedNs -= dropped.durationNs
                s.stats.droppedNs += dropped.durationNs
                if let existing = gap {
                    gap = AudioGap(laneID: existing.laneID, captureEpoch: existing.captureEpoch, startNs: existing.startNs, endNs: dropped.sourceEndNs, reason: .queueOverflow)
                } else {
                    gap = AudioGap(laneID: dropped.laneID, captureEpoch: dropped.captureEpoch, startNs: dropped.sourceStartNs, endNs: dropped.sourceEndNs, reason: .queueOverflow)
                }
            }
            if s.head > 64, s.head * 2 > s.packets.count {
                s.packets.removeFirst(s.head)
                s.head = 0
            }
            return gap
        }
    }

    public func pop() -> AudioPacket? {
        state.withLock { s in
            guard s.head < s.packets.count else { return nil }
            let p = s.packets[s.head]
            s.head += 1
            s.stats.popped += 1
            s.stats.queuedNs -= p.durationNs
            if s.head == s.packets.count {
                s.packets.removeAll(keepingCapacity: true)
                s.head = 0
            }
            return p
        }
    }

    public func drain() -> [AudioPacket] {
        state.withLock { s in
            let out = Array(s.packets[s.head...])
            s.stats.popped += UInt64(out.count)
            s.stats.queuedNs = 0
            s.packets.removeAll(keepingCapacity: true)
            s.head = 0
            return out
        }
    }

    public var stats: Stats {
        state.withLock { $0.stats }
    }

    public var isEmpty: Bool {
        state.withLock { $0.head >= $0.packets.count }
    }
}
