import Testing
import Foundation
@testable import EngineKit
@testable import CaptionDomain

private let ctx = SpeechSegmenter.Context(sessionID: "s", laneID: "remote", providerEpoch: 1, captureEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans")

private func chunk(_ s: Double, _ e: Double, _ text: String, final: Bool) -> TranscriptChunk {
    TranscriptChunk(startNs: Int64(s * 1e9), endNs: Int64(e * 1e9), text: text, isFinal: final)
}

@Suite("Speech result → caption segment mapping")
struct SpeechSegmenterTests {

    @Test("Timing-only revisions keep a useful translation and retain the final audio range")
    func timingUpdatesDoNotRetranslateOrInvalidateTheCurrentWords() {
        var seg = SpeechSegmenter()
        var reducer = CaptionReducer(sessionID: "s")
        let first = seg.apply(chunk(0, 1, "Please wait", final: false), context: ctx)
        for event in first.events { _ = reducer.apply(event) }
        let timing = seg.apply(chunk(0, 2, "Please wait", final: false), context: ctx)
        #expect(timing.events.isEmpty && timing.translation == nil)
        _ = reducer.apply(seg.translationEvent(for: first.translation!, text: "请稍候", context: ctx))
        #expect(reducer.snapshot.segments.first?.translation?.text == "请稍候")
        let final = seg.apply(chunk(0, 1.5, "", final: true), context: ctx)
        #expect(final.events.first?.endNs == 2_000_000_000)
        #expect(final.translation?.isFinal == true && final.translation?.revision == 2)
        var changed = SpeechSegmenter()
        _ = changed.apply(chunk(0, 1, "Please wait", final: false), context: ctx)
        #expect(changed.apply(chunk(0, 2, "Please wait here", final: false), context: ctx).translation != nil)
    }

    @Test("Volatile results revise one segment; the final closes it; the next volatile opens a new one")
    func volatileThenFinal() {
        var seg = SpeechSegmenter()
        let a = seg.apply(chunk(5.0, 6.1, "Please", final: false), context: ctx)
        let b = seg.apply(chunk(5.0, 6.1, "Please do", final: false), context: ctx)
        let c = seg.apply(chunk(5.0, 8.0, "Please do not restart the server yet.", final: true), context: ctx)
        let d = seg.apply(chunk(8.0, 9.0, " The", final: false), context: ctx)
        #expect(a.events.count == 1 && a.events[0].type == .sourceReplace && a.events[0].revision == 1)
        #expect(b.events[0].revision == 2 && b.events[0].segmentID == a.events[0].segmentID)
        #expect(c.events[0].type == .sourceFinal && c.events[0].revision == 3 && c.events[0].segmentID == a.events[0].segmentID)
        #expect(c.events[0].startNs == 5_000_000_000 && c.events[0].endNs == 8_000_000_000)
        #expect(c.translation == SpeechSegmenter.TranslationRequest(segmentID: a.events[0].segmentID!, revision: 3, text: "Please do not restart the server yet.", isFinal: true))
        #expect(d.events[0].segmentID != a.events[0].segmentID, "a finalized segment id is never reused")
        #expect(d.events[0].revision == 1 && d.events[0].text == "The")
        // Event ids are unique across the run.
        let ids = [a, b, c, d].flatMap(\.events).map(\.eventID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("A final with no open segment creates one; identical volatile text is not re-emitted")
    func finalAloneAndDedup() {
        var seg = SpeechSegmenter()
        let f = seg.apply(chunk(0, 1, "Thank you.", final: true), context: ctx)
        #expect(f.events.count == 1 && f.events[0].type == .sourceFinal && f.events[0].revision == 1)
        _ = seg.apply(chunk(1, 2, "Any", final: false), context: ctx)
        let same = seg.apply(chunk(1, 2, "Any", final: false), context: ctx)
        #expect(same.events.isEmpty)
        let blankFinal = seg.apply(chunk(1, 2.5, "   ", final: true), context: ctx)
        #expect(blankFinal.events.count == 1 && blankFinal.events[0].type == .sourceFinal && blankFinal.events[0].text == "Any")
        #expect(!seg.hasOpenSegment)
    }

    @Test("Short partials are shown but not translated; long partials request a preview translation")
    func partialTranslationGate() {
        var seg = SpeechSegmenter()
        let short = seg.apply(chunk(0, 1, "Hi", final: false), context: ctx)
        #expect(short.events.count == 1 && short.translation == nil)
        let long = seg.apply(chunk(0, 2, "Hi there everyone", final: false), context: ctx)
        #expect(long.translation?.isFinal == false && long.translation?.revision == 2)
    }

    @Test("Through the reducer: finals get final translations, a late partial translation never overrides one")
    func reducerRoundTrip() {
        var seg = SpeechSegmenter()
        var reducer = CaptionReducer(sessionID: "s")
        func feed(_ out: SpeechSegmenter.Output) { for e in out.events { _ = reducer.apply(e) } }
        let p1 = seg.apply(chunk(0, 1, "Please do not", final: false), context: ctx)
        feed(p1)
        let partialReq = p1.translation!
        let f1 = seg.apply(chunk(0, 2, "Please do not restart the server yet.", final: true), context: ctx)
        feed(f1)
        // Final translation arrives first, then the stale partial one.
        _ = reducer.apply(seg.translationEvent(for: f1.translation!, text: "请先不要重启服务器。", context: ctx))
        let late = reducer.apply(seg.translationEvent(for: partialReq, text: "请不要", context: ctx))
        #expect(late.contains { if case .dropped(_, let r) = $0 { return r == .staleTranslation } else { return false } })
        let s = reducer.snapshot.segments
        #expect(s.count == 1)
        #expect(s[0].presentationState == .final)
        #expect(s[0].translation?.text == "请先不要重启服务器。")
        // Next sentence's partial after the final is a new preview segment.
        feed(seg.apply(chunk(2, 3, " The retry", final: false), context: ctx))
        #expect(reducer.snapshot.segments.count == 2)
        #expect(reducer.snapshot.segments[1].presentationState == .preview)
        #expect(reducer.snapshot.segments[1].sourceText == "The retry")
    }
}
