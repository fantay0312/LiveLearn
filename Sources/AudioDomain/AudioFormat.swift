import Foundation

/// Describes a PCM stream shape. The capture domain keeps the device's real format;
/// provider adapters convert at their own boundary. Nothing in the app assumes 16 kHz.
public struct AudioFormatDescriptor: Sendable, Hashable, Codable {
    public var sampleRate: Double
    public var channelCount: Int
    public var sampleType: SampleType
    public var isInterleaved: Bool

    /// The PCM layouts the capture layer knows how to decode. Anything else is rejected at
    /// start instead of being misread as one of these.
    public enum SampleType: String, Sendable, Codable {
        case float32
        case float64
        case int16
        /// 24-bit packed in 3 bytes.
        case int24
        /// 32-bit integer, or 24-bit high-aligned in a 32-bit container.
        case int32

        public var label: String {
            switch self {
            case .float32: return "Float32"
            case .float64: return "Float64"
            case .int16: return "Int16"
            case .int24: return "Int24"
            case .int32: return "Int32"
            }
        }
    }

    public init(sampleRate: Double, channelCount: Int, sampleType: SampleType = .float32, isInterleaved: Bool = false) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sampleType = sampleType
        self.isInterleaved = isInterleaved
    }

    /// Human readable, e.g. "48 kHz · 2ch · Float32".
    public var summary: String {
        let khz = sampleRate / 1000
        let rate = khz == khz.rounded() ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        return "\(rate) · \(channelCount)ch · \(sampleType.label)"
    }
}

/// Owned, de-interleaved Float32 audio. Never references a callback's transient pointer.
public struct OwnedAudioBuffer: Sendable {
    public var channels: [[Float]]
    public var frameCount: Int

    public init(channels: [[Float]]) {
        self.channels = channels
        self.frameCount = channels.first?.count ?? 0
    }

    public init(mono: [Float]) {
        self.channels = [mono]
        self.frameCount = mono.count
    }

    /// Equal-weight mixdown. Stereo content with phase cancellation is a known limitation;
    /// provider adapters may choose a different strategy.
    public func mixedToMono() -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        var out = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channels.count)
        for ch in channels {
            for i in 0..<min(frameCount, ch.count) {
                out[i] += ch[i] * scale
            }
        }
        return out
    }

    /// RMS and peak of the mono mixdown. Cheap enough for the worker thread.
    public func energy() -> (rms: Float, peak: Float) {
        let mono = mixedToMono()
        guard !mono.isEmpty else { return (0, 0) }
        var sum: Float = 0
        var peak: Float = 0
        for s in mono {
            sum += s * s
            let a = abs(s)
            if a > peak { peak = a }
        }
        return ((sum / Float(mono.count)).squareRoot(), peak)
    }
}

extension AudioFormatDescriptor {
    public func durationNs(frameCount: Int) -> Int64 {
        Int64((Double(frameCount) / sampleRate) * 1_000_000_000)
    }
}
