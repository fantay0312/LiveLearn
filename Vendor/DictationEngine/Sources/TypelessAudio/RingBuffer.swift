// Lock-free single-producer / single-consumer ring of Float32 samples. The producer is the
// CoreAudio IO thread (no allocation, no locks, no ARC traffic beyond the owning reference).
import Synchronization

public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int
    private let mask: Int
    private let head = Atomic<Int>(0) // next write position (producer-owned)
    private let tail = Atomic<Int>(0) // next read position (consumer-owned)
    public let overruns = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int) {
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    public var available: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    /// Producer side. Drops the whole chunk (and counts an overrun) if it does not fit.
    @inline(__always)
    public func write(_ src: UnsafePointer<Float>, count: Int) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h - t + count > capacity {
            overruns.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let start = h & mask
        let first = min(count, capacity - start)
        (storage + start).update(from: src, count: first)
        if first < count { storage.update(from: src + first, count: count - first) }
        head.store(h + count, ordering: .releasing)
    }

    /// Consumer side. Returns the number of samples copied (<= count).
    @inline(__always)
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(count, h - t)
        if n == 0 { return 0 }
        let start = t & mask
        let first = min(n, capacity - start)
        dst.update(from: storage + start, count: first)
        if first < n { (dst + first).update(from: storage, count: n - first) }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}
