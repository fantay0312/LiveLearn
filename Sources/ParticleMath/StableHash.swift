import Accelerate
import Foundation

/// A deterministic fraction in `0..<1` for a text key (FNV-1a with a final avalanche). The same
/// function the vocabulary star map has always used, so every star keeps its place.
public enum StableHash {
    public static func fraction(_ text: String, salt: UInt64 = 0) -> Double {
        var hash: UInt64 = 14695981039346656037 &+ salt
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        hash ^= hash >> 33
        hash = hash &* 0xff51afd7ed558ccd
        hash ^= hash >> 33
        return Double(hash & 0xFFFFFF) / Double(0x1000000)
    }
}

/// A fixed-capacity Float buffer that is allocated once and reused every frame. Plain pointers
/// rather than arrays: pointer subscripts stay cheap in unoptimised builds and nothing here is
/// ever resized, retained or copied on the hot path.
final class FloatPlane {
    let count: Int
    let base: UnsafeMutablePointer<Float>

    init(_ count: Int) {
        self.count = count
        base = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
        base.initialize(repeating: 0, count: max(1, count))
    }

    deinit { base.deallocate() }
}

/// Vectorised transcendental functions over whole planes (Accelerate's vForce): a few thousand
/// sines cost about as much as a dozen scalar calls.
enum ParticleTrig {
    static func sin(_ out: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, _ count: Int) {
        var n = Int32(count)
        vvsinf(out, x, &n)
    }

    static func cos(_ out: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, _ count: Int) {
        var n = Int32(count)
        vvcosf(out, x, &n)
    }

    static func exp(_ out: UnsafeMutablePointer<Float>, _ x: UnsafePointer<Float>, _ count: Int) {
        var n = Int32(count)
        vvexpf(out, x, &n)
    }
}
