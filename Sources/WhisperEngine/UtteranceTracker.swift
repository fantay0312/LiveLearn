import Foundation

/// Cuts the packet stream into utterances for Whisper, which decodes whole clips rather than a
/// stream. Pure value logic, driven by each packet's RMS (the lane already measures it):
///
/// - an utterance opens on the first voiced packet and takes up to 300 ms of the silence
///   before it, so word onsets are not clipped;
/// - while it is open, every second of new audio asks for a partial decode of the whole clip;
/// - 500 ms of silence after at least 300 ms of speech closes it (a final decode); a clip that
///   reaches 25 s closes anyway, well under Whisper's 30 s window;
/// - a voiced blip shorter than 300 ms is dropped without a decode, which is where most
///   "Thank you." hallucinations would otherwise come from.
///
/// Times are session nanoseconds from the packets; the clip is contiguous by construction
/// because a discontinuity closes whatever was open.
public struct UtteranceTracker: Sendable {
    public struct Settings: Sendable, Equatable {
        public var sampleRate = 16_000
        /// Packet RMS at or above this counts as voice.
        public var voiceRMS: Float = 0.010
        public var preRollMs = 300
        public var minSpeechMs = 300
        /// Silence that ends a sentence. Speakers pause 400–800 ms between sentences; server
        /// VADs default to 500 ms; the app's synthetic test voice pauses only 200–300 ms.
        public var endSilenceMs = 500
        public var partialEveryMs = 1000
        public var maxUtteranceMs = 25_000
        /// Silence kept at the end of a final clip so the last word is not cut.
        public var keepTailSilenceMs = 200

        public init() {}
    }

    public struct Utterance: Sendable, Equatable {
        public var samples: [Float]
        public var startNs: Int64
        public var endNs: Int64
    }

    public enum Action: Sendable, Equatable {
        case partial(Utterance)
        case final(Utterance)
    }

    public let settings: Settings
    private var preRoll: [Float] = []
    private var buffer: [Float] = []
    private var startNs: Int64?
    private var speechSamples = 0
    private var trailingSilence = 0
    private var sinceDecode = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var isOpen: Bool { startNs != nil }

    private func samples(ms: Int) -> Int { settings.sampleRate * ms / 1000 }
    private func ns(samples: Int) -> Int64 { Int64(samples) * 1_000_000_000 / Int64(settings.sampleRate) }

    public mutating func ingest(samples: [Float], rms: Float, startNs packetStartNs: Int64, discontinuity: Bool) -> [Action] {
        var out: [Action] = []
        guard !samples.isEmpty else { return out }
        if discontinuity, let a = flush() { out.append(a) }
        let voiced = rms >= settings.voiceRMS

        if startNs == nil {
            guard voiced else {
                preRoll.append(contentsOf: samples)
                let keep = self.samples(ms: settings.preRollMs)
                if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
                return out
            }
            buffer = preRoll + samples
            startNs = packetStartNs - ns(samples: preRoll.count)
            preRoll = []
            speechSamples = samples.count
            trailingSilence = 0
            sinceDecode = buffer.count
        } else {
            buffer.append(contentsOf: samples)
            if voiced {
                speechSamples += samples.count
                trailingSilence = 0
            } else {
                trailingSilence += samples.count
            }
            sinceDecode += samples.count
        }

        if trailingSilence >= self.samples(ms: settings.endSilenceMs) || buffer.count >= self.samples(ms: settings.maxUtteranceMs) {
            if let a = flush() { out.append(a) }
            return out
        }
        // A partial only while the speaker is still going: re-decoding a clip whose newest
        // second is silence shows nothing new and delays the final.
        if voiced, sinceDecode >= self.samples(ms: settings.partialEveryMs), speechSamples >= self.samples(ms: settings.minSpeechMs) {
            sinceDecode = 0
            out.append(.partial(current(trimTail: false)))
        }
        return out
    }

    /// Closes the open utterance (pause, stop, discontinuity, silence): a final decode when it
    /// held enough speech, nothing when it was only a blip.
    public mutating func flush() -> Action? {
        guard startNs != nil else { return nil }
        defer { reset() }
        guard speechSamples >= samples(ms: settings.minSpeechMs) else { return nil }
        return .final(current(trimTail: true))
    }

    private func current(trimTail: Bool) -> Utterance {
        var clip = buffer
        if trimTail {
            let keep = samples(ms: settings.keepTailSilenceMs)
            if trailingSilence > keep { clip.removeLast(trailingSilence - keep) }
        }
        let start = startNs ?? 0
        return Utterance(samples: clip, startNs: start, endNs: start + ns(samples: clip.count))
    }

    private mutating func reset() {
        // The tail of a closed utterance is silence; keep a little as the next pre-roll.
        let keep = samples(ms: settings.preRollMs)
        if trailingSilence > 0 {
            preRoll = Array(buffer.suffix(min(keep, trailingSilence)))
        } else {
            preRoll = []
        }
        buffer = []
        startNs = nil
        speechSamples = 0
        trailingSilence = 0
        sinceDecode = 0
    }
}

/// What Whisper says when it hears nothing: subtitle credits and thanks it learned from
/// captions. A decode that is only that is treated as silence.
public enum WhisperTextFilter {
    static let junk: Set<String> = [
        "字幕由amara.org社区提供", "字幕由 amara.org 社区提供", "subtitles by the amara.org community",
        "請不吝點贊 訂閱 轉發 打賞支持明鏡與點點欄目", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "谢谢观看", "謝謝觀看", "谢谢大家", "谢谢", "thank you", "thank you.", "thanks for watching", "thanks for watching.",
        "thank you for watching", "thank you for watching.", "you", "bye", "bye.",
        "ご視聴ありがとうございました", "ご視聴ありがとうございました。", "字幕提供", "by the amara.org community",
    ]

    /// The clip's text, or "" when it is silence or a hallucination.
    public static func text(of result: WhisperDecodeResult) -> String {
        let kept = result.segments.filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1.0) }
        var s = kept.map(\.text).joined()
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if key.isEmpty || junk.contains(key) || junk.contains(s.lowercased()) { return "" }
        return s
    }
}
