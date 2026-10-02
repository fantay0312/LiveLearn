// Small shared helpers: files, hashing, monotonic clock, percentiles.
import Foundation
import CommonCrypto

public func writeFile(path: String, bytes: [UInt8]) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: url)
}

public func readFile(path: String) throws -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw NSError(domain: "TypelessCore", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot read file: \(path)"])
    }
    return [UInt8](data)
}

public func sha256Hex(_ bytes: UnsafeRawBufferPointer) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
    var out = ""
    out.reserveCapacity(64)
    for b in digest { out += String(format: "%02x", b) }
    return out
}

public func sha256Hex(_ bytes: [UInt8]) -> String { bytes.withUnsafeBytes { sha256Hex($0) } }

/// First 12 hex chars of SHA-256 — the only form in which device_id/appkey/URL may be logged (§25).
public func sha12(_ bytes: [UInt8]) -> String { String(sha256Hex(bytes).prefix(12)) }
public func sha12(_ text: String) -> String { sha12(Array(text.utf8)) }

public func sha1Digest(_ bytes: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    bytes.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG($0.count), &digest) }
    return digest
}

/// Monotonic nanoseconds (CLOCK_UPTIME_RAW == mach_absolute_time scaled), ~20 ns per call.
@inline(__always)
public func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@inline(__always)
public func wallClockMs() -> Int64 {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
}

/// Percentile summary used by `--stats` and `bench`.
public struct LatencySeries: Sendable {
    public private(set) var samplesNs: [UInt64] = []
    public init() {}
    public mutating func add(ns: UInt64) { samplesNs.append(ns) }
    public var count: Int { samplesNs.count }

    public func percentileMs(_ p: Double) -> Double {
        guard !samplesNs.isEmpty else { return 0 }
        let sorted = samplesNs.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded())
        return Double(sorted[min(max(rank, 0), sorted.count - 1)]) / 1_000_000
    }

    public var meanMs: Double {
        guard !samplesNs.isEmpty else { return 0 }
        return Double(samplesNs.reduce(0, +)) / Double(samplesNs.count) / 1_000_000
    }

    public func summary() -> JSONValue {
        func r(_ v: Double) -> JSONValue { .double((v * 1000).rounded() / 1000) }
        return .obj([
            ("count", .int(Int64(count))),
            ("p50_ms", r(percentileMs(0.50))),
            ("p95_ms", r(percentileMs(0.95))),
            ("p99_ms", r(percentileMs(0.99))),
            ("mean_ms", r(meanMs)),
        ])
    }
}

public func getEnv(_ name: String) -> String? {
    guard let v = getenv(name) else { return nil }
    return String(cString: v)
}

public func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }
