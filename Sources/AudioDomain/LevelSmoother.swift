import Foundation

/// Turns raw RMS into the "breath line" level: fast attack, slow release.
/// Pure value logic so the UI and tests share it.
public struct LevelSmoother: Sendable {
    public var attackSeconds: Double
    public var releaseSeconds: Double
    public private(set) var value: Float = 0
    private var lastNs: Int64?

    public init(attackSeconds: Double = 0.06, releaseSeconds: Double = 0.4) {
        self.attackSeconds = attackSeconds
        self.releaseSeconds = releaseSeconds
    }

    /// Feeds a new RMS sample observed at `nowNs`. Returns the smoothed display level 0...1.
    @discardableResult
    public mutating func feed(rms: Float, nowNs: Int64) -> Float {
        // Perceptual mapping: -50 dBFS ... -8 dBFS -> 0...1
        let db = 20 * log10(max(rms, 1e-6))
        let target = Float(min(max((Double(db) + 50) / 42, 0), 1))
        guard let last = lastNs else {
            lastNs = nowNs
            value = target
            return value
        }
        let dt = max(Double(nowNs - last) / 1_000_000_000, 0)
        lastNs = nowNs
        let tau = target > value ? attackSeconds : releaseSeconds
        let alpha = Float(1 - exp(-dt / tau))
        value += (target - value) * alpha
        return value
    }

    public mutating func reset() {
        value = 0
        lastNs = nil
    }
}
