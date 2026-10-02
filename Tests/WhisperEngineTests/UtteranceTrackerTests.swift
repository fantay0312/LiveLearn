import Testing
import Foundation
@testable import WhisperEngine

private func packet(ms: Int, value: Float) -> [Float] { Array(repeating: value, count: 16 * ms) }

@Suite("Whisper utterance cutting")
struct UtteranceTrackerTests {
    @Test("Silence alone never opens an utterance; the pre-roll stays bounded")
    func silence() {
        var t = UtteranceTracker()
        for i in 0..<50 {
            let out = t.ingest(samples: packet(ms: 100, value: 0), rms: 0, startNs: Int64(i) * 100_000_000, discontinuity: false)
            #expect(out.isEmpty)
        }
        #expect(!t.isOpen)
        #expect(t.flush() == nil)
    }

    @Test("Speech opens with pre-roll, asks for a partial every second, and closes after 500 ms of silence")
    func speechThenSilence() {
        var t = UtteranceTracker()
        var now: Int64 = 0
        func feed(_ ms: Int, _ rms: Float) -> [UtteranceTracker.Action] {
            let out = t.ingest(samples: packet(ms: 100, value: rms), rms: rms, startNs: now, discontinuity: false)
            now += 100_000_000
            return out
        }
        // 500 ms of silence first: only 300 ms of it may be kept as pre-roll.
        for _ in 0..<5 { #expect(feed(100, 0).isEmpty) }
        var partials: [UtteranceTracker.Utterance] = []
        var finals: [UtteranceTracker.Utterance] = []
        // 1.5 s of speech.
        for _ in 0..<15 {
            for a in feed(100, 0.05) {
                if case .partial(let u) = a { partials.append(u) }
                if case .final(let u) = a { finals.append(u) }
            }
        }
        #expect(partials.count == 1, "one partial after the first second of speech")
        #expect(finals.isEmpty)
        let opened = partials[0]
        // Opened 300 ms before the first voiced packet (which started at 500 ms).
        #expect(opened.startNs == 200_000_000)
        // 700 ms of silence closes it.
        for _ in 0..<7 {
            for a in feed(100, 0) {
                if case .final(let u) = a { finals.append(u) }
            }
        }
        #expect(finals.count == 1)
        let final = finals[0]
        #expect(final.startNs == 200_000_000)
        // Pre-roll 300 ms + speech 1500 ms + kept tail 200 ms = 2.0 s of audio.
        #expect(final.samples.count == 16 * 2000)
        #expect(final.endNs == 200_000_000 + 2_000_000_000)
        #expect(!t.isOpen)
    }

    @Test("A blip shorter than 300 ms is dropped without a decode")
    func blip() {
        var t = UtteranceTracker()
        var out = t.ingest(samples: packet(ms: 100, value: 0.05), rms: 0.05, startNs: 0, discontinuity: false)
        #expect(out.isEmpty)
        out = t.ingest(samples: packet(ms: 100, value: 0.05), rms: 0.05, startNs: 100_000_000, discontinuity: false)
        #expect(out.isEmpty)
        for i in 0..<8 {
            out = t.ingest(samples: packet(ms: 100, value: 0), rms: 0, startNs: 200_000_000 + Int64(i) * 100_000_000, discontinuity: false)
            #expect(out.isEmpty)
        }
        #expect(!t.isOpen)
    }

    @Test("A 25 s clip closes on its own, under Whisper's window; a discontinuity closes at once")
    func capAndDiscontinuity() {
        var t = UtteranceTracker()
        var finals = 0
        var now: Int64 = 0
        for _ in 0..<260 {
            for a in t.ingest(samples: packet(ms: 100, value: 0.05), rms: 0.05, startNs: now, discontinuity: false) {
                if case .final(let u) = a {
                    finals += 1
                    #expect(u.samples.count <= 16 * 25_000)
                }
            }
            now += 100_000_000
        }
        #expect(finals == 1)
        #expect(t.isOpen, "the clip after the cap is open again")
        // A discontinuity with enough speech behind it flushes first, then the new packet starts fresh.
        for _ in 0..<3 { _ = t.ingest(samples: packet(ms: 100, value: 0.05), rms: 0.05, startNs: now, discontinuity: false); now += 100_000_000 }
        let out = t.ingest(samples: packet(ms: 100, value: 0.05), rms: 0.05, startNs: now + 5_000_000_000, discontinuity: true)
        #expect(out.contains { if case .final = $0 { return true } else { return false } })
        #expect(t.isOpen)
    }
}

@Suite("Whisper text filter")
struct WhisperTextFilterTests {
    @Test("Credits and thanks Whisper invents on silence count as nothing; real text is joined")
    func junk() {
        let thanks = WhisperDecodeResult(segments: [WhisperSegment(start: 0, end: 1, text: " Thank you.")])
        #expect(WhisperTextFilter.text(of: thanks) == "")
        let credits = WhisperDecodeResult(segments: [WhisperSegment(start: 0, end: 2, text: "字幕由Amara.org社区提供")])
        #expect(WhisperTextFilter.text(of: credits) == "")
        let real = WhisperDecodeResult(segments: [WhisperSegment(start: 0, end: 1, text: " Before we touch"), WhisperSegment(start: 1, end: 2, text: " anything in production.")])
        #expect(WhisperTextFilter.text(of: real) == "Before we touch anything in production.")
        let noSpeech = WhisperDecodeResult(segments: [WhisperSegment(start: 0, end: 1, text: " hello", noSpeechProb: 0.9, avgLogprob: -1.5)])
        #expect(WhisperTextFilter.text(of: noSpeech) == "")
    }

    @Test("Catalog codes map onto Whisper's ISO list")
    func languages() {
        #expect(WhisperLanguage.code("zh-Hans") == "zh")
        #expect(WhisperLanguage.code("pt-BR") == "pt")
        #expect(WhisperLanguage.code("nb") == "no")
        #expect(WhisperLanguage.isSupported("ja"))
        #expect(WhisperLanguage.isSupported("yue"))
        #expect(WhisperLanguage.isSupported("zh-Hant"))
    }
}
