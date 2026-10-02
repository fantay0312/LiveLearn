import Foundation
import CaptionDomain

/// A scripted timeline the fake provider plays back. Times are milliseconds since `open`.
public struct FakeScript: Sendable, Codable {
    public enum Step: Sendable, Codable, Equatable {
        case source(atMs: Int, segment: String, revision: Int, text: String, startMs: Int, endMs: Int, isFinal: Bool, eventID: String?)
        case translation(atMs: Int, translationID: String, refs: [SourceRef], text: String, isFinal: Bool, eventID: String?)
        case gap(atMs: Int, startMs: Int, endMs: Int, reason: String)
        case disconnect(atMs: Int, reconnectAfterMs: Int)
        /// Emits an event stamped with the previous provider epoch, after a reconnect.
        case staleFromPreviousEpoch(atMs: Int, segment: String, revision: Int, text: String)
        case waitForVoice(atMs: Int)
        case end(atMs: Int)

        public var atMs: Int {
            switch self {
            case .source(let a, _, _, _, _, _, _, _): return a
            case .translation(let a, _, _, _, _, _): return a
            case .gap(let a, _, _, _): return a
            case .disconnect(let a, _): return a
            case .staleFromPreviousEpoch(let a, _, _, _): return a
            case .waitForVoice(let a): return a
            case .end(let a): return a
            }
        }
    }

    public var name: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var steps: [Step]

    public init(name: String, sourceLanguage: String, targetLanguage: String, steps: [Step]) {
        self.name = name
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.steps = steps.sorted { $0.atMs < $1.atMs }
    }
}

// MARK: - Builders

public struct FakeSentence: Sendable {
    public var source: String
    public var target: String
    /// Optional earlier misheard partial that gets revised (exercises revision handling).
    public var misheard: String?
    /// Words per partial step for latin text; characters for CJK.
    public init(_ source: String, _ target: String, misheard: String? = nil) {
        self.source = source
        self.target = target
        self.misheard = misheard
    }
}

extension FakeScript {
    /// Builds a natural-feeling timeline: source partials grow word by word, a final lands,
    /// the translation arrives a little later. Realistic pacing, no model.
    public static func lecture(name: String = "lecture", sourceLanguage: String = "en", targetLanguage: String = "zh-Hans", sentences: [FakeSentence], startMs: Int = 800, gateOnVoice: Bool = false, translationDelayMs: Int = 700, wordIntervalMs: Int = 230, pauseBetweenMs: Int = 900) -> FakeScript {
        var steps: [Step] = []
        var t = startMs
        var idx = 0
        for sentence in sentences {
            idx += 1
            let seg = String(format: "seg-%03d", idx)
            if gateOnVoice { steps.append(.waitForVoice(atMs: t)) }
            let words = tokenize(sentence.source)
            let segStart = t
            var revision = 0
            var partialWords: [String] = []
            let misheardCut: Int? = sentence.misheard == nil ? nil : max(1, words.count / 2)
            for (i, w) in words.enumerated() {
                revision += 1
                partialWords.append(w)
                var text = join(partialWords)
                if let cut = misheardCut, i == cut - 1, let mis = sentence.misheard {
                    text = mis
                }
                let isLast = i == words.count - 1
                steps.append(.source(atMs: t, segment: seg, revision: revision, text: isLast ? sentence.source : text, startMs: segStart, endMs: t + wordIntervalMs, isFinal: false, eventID: nil))
                t += wordIntervalMs
            }
            let segEnd = t
            revision += 1
            steps.append(.source(atMs: t + 120, segment: seg, revision: revision, text: sentence.source, startMs: segStart, endMs: segEnd, isFinal: true, eventID: nil))
            steps.append(.translation(atMs: t + 120 + translationDelayMs, translationID: "tr-\(seg)", refs: [SourceRef(segmentID: seg, revision: revision)], text: sentence.target, isFinal: true, eventID: nil))
            t += pauseBetweenMs
        }
        steps.append(.end(atMs: t + translationDelayMs + 400))
        return FakeScript(name: name, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, steps: steps)
    }

    static func tokenize(_ s: String) -> [String] {
        let hasCJK = s.unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0x9FFF }
        if hasCJK {
            // Group 2 characters per step so it feels like speech, not typing.
            let chars = Array(s)
            return stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<min($0 + 2, chars.count)]) }
        }
        return s.split(separator: " ").map(String.init)
    }

    static func join(_ tokens: [String]) -> String {
        let hasCJK = tokens.joined().unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0x9FFF }
        return hasCJK ? tokens.joined() : tokens.joined(separator: " ")
    }
}

// MARK: - Demo content (original text written for this project)

extension FakeScript {
    /// Language pairs the demo can play. Anything else must be refused before a session starts;
    /// the scripts do not react to what is actually being said, so a mismatched pair would show
    /// captions in the wrong language.
    public static let demoPairs: [(source: String, target: String)] = [("en", "zh-Hans"), ("zh-Hans", "en")]

    /// The demo script for a language pair, or nil when the pair has no script.
    /// `gateOnVoice` makes every sentence wait for real audio energy (microphone lanes).
    public static func demo(source: String?, target: String, gateOnVoice: Bool) -> FakeScript? {
        switch (source, target) {
        case ("en", "zh-Hans"):
            return .lecture(name: gateOnVoice ? "demo-talk-voice" : "demo-talk", sentences: talkSentences, startMs: gateOnVoice ? 500 : 1200, gateOnVoice: gateOnVoice)
        case ("zh-Hans", "en"):
            return .lecture(name: gateOnVoice ? "demo-voice" : "demo-voice-timed", sourceLanguage: "zh-Hans", targetLanguage: "en", sentences: voiceSentences, startMs: gateOnVoice ? 500 : 1200, gateOnVoice: gateOnVoice, wordIntervalMs: 260)
        default:
            return nil
        }
    }

    private static let talkSentences: [FakeSentence] = [
        FakeSentence("Before we touch anything in production, let's look at what the logs are actually saying.",
                     "在动生产环境之前，我们先看看日志到底在说什么。"),
        FakeSentence("Please do not restart the server yet.",
                     "请先不要重启服务器。"),
        FakeSentence("The retry storm you are seeing is a symptom, not the cause.",
                     "你看到的重试风暴是症状，不是原因。"),
        FakeSentence("If we roll back now, we lose the evidence we need for the postmortem.",
                     "如果现在回滚，我们会失去复盘所需的证据。",
                     misheard: "If we roll back now, we lose the evidence we need for the post"),
        FakeSentence("So the plan is: freeze deploys, capture the traces, then decide.",
                     "所以计划是：冻结发布，抓取链路追踪，然后再决定。"),
        FakeSentence("Thank you.", "谢谢。"),
        FakeSentence("Thank you.", "谢谢。"),
        FakeSentence("Any questions before we split into two groups?",
                     "在分成两组之前，有什么问题吗？"),
    ]

    private static let voiceSentences: [FakeSentence] = [
        FakeSentence("日志在哪里可以看到？", "Where can I see the logs?"),
        FakeSentence("我们这边的网关也在报超时。", "Our gateway is reporting timeouts as well."),
        FakeSentence("好的，我先不动配置。", "Okay, I will leave the config alone for now."),
    ]

    /// English technical talk → Simplified Chinese. Plays on a timer.
    public static let demoTalk: FakeScript = demo(source: "en", target: "zh-Hans", gateOnVoice: false)!

    /// Microphone lane: waits for the user's voice before each sentence (zh → en).
    public static let demoVoice: FakeScript = demo(source: "zh-Hans", target: "en", gateOnVoice: true)!

    /// Edge-case fixture: duplicates, late translation for an old revision, reconnect with a stale event.
    public static let edgeCases: FakeScript = FakeScript(
        name: "edge-cases",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        steps: [
            .source(atMs: 0, segment: "s1", revision: 1, text: "Thank you.", startMs: 0, endMs: 600, isFinal: true, eventID: "e1"),
            .translation(atMs: 50, translationID: "t1", refs: [SourceRef(segmentID: "s1", revision: 1)], text: "谢谢。", isFinal: true, eventID: "e2"),
            .source(atMs: 100, segment: "s2", revision: 1, text: "Thank you.", startMs: 700, endMs: 1300, isFinal: true, eventID: "e3"),
            .translation(atMs: 150, translationID: "t2", refs: [SourceRef(segmentID: "s2", revision: 1)], text: "谢谢。", isFinal: true, eventID: "e4"),
            // duplicate delivery of e3
            .source(atMs: 160, segment: "s2", revision: 1, text: "Thank you.", startMs: 700, endMs: 1300, isFinal: true, eventID: "e3"),
            // s3 r1 then r2, translation for r1 arrives after r2's translation
            .source(atMs: 200, segment: "s3", revision: 1, text: "We lose the evidence for the post", startMs: 1400, endMs: 2000, isFinal: false, eventID: "e5"),
            .source(atMs: 260, segment: "s3", revision: 2, text: "We lose the evidence for the postmortem.", startMs: 1400, endMs: 2400, isFinal: true, eventID: "e6"),
            .translation(atMs: 300, translationID: "t3b", refs: [SourceRef(segmentID: "s3", revision: 2)], text: "我们会失去复盘的证据。", isFinal: true, eventID: "e7"),
            .translation(atMs: 340, translationID: "t3a", refs: [SourceRef(segmentID: "s3", revision: 1)], text: "我们失去了给帖子的证据", isFinal: false, eventID: "e8"),
            .gap(atMs: 400, startMs: 2400, endMs: 4700, reason: "network"),
            .disconnect(atMs: 420, reconnectAfterMs: 100),
            .source(atMs: 600, segment: "s4", revision: 1, text: "Any questions?", startMs: 4800, endMs: 5400, isFinal: true, eventID: "e9"),
            .staleFromPreviousEpoch(atMs: 640, segment: "s3", revision: 3, text: "SHOULD NOT APPEAR"),
            .translation(atMs: 700, translationID: "t4", refs: [SourceRef(segmentID: "s4", revision: 1)], text: "有问题吗？", isFinal: true, eventID: "e10"),
            .end(atMs: 800),
        ]
    )
}
