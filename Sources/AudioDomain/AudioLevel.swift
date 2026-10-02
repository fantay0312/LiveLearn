import Foundation

/// The one place that decides what "audible" means. The capture layer uses it for its coarse
/// health state, the lane for the last-audio watermark, so the two can never disagree about
/// whether a packet carried sound.
public enum AudioLevel {
    /// RMS of the mono mixdown above which a packet counts as sound (about −66 dBFS).
    public static let audibleRMS: Float = 0.0005

    public static func isAudible(rms: Float) -> Bool { rms > audibleRMS }

    /// Cheap RMS estimate for the audio thread: every `stride`-th sample of one channel.
    /// Good enough to separate silence from signal; the lane computes the exact value.
    public static func stridedRMS(_ samples: [Float], stride: Int = 16) -> Float {
        guard !samples.isEmpty else { return 0 }
        let step = max(1, stride)
        var sum: Float = 0
        var n = 0
        var i = 0
        while i < samples.count {
            let s = samples[i]
            sum += s * s
            n += 1
            i += step
        }
        return n == 0 ? 0 : (sum / Float(n)).squareRoot()
    }
}
