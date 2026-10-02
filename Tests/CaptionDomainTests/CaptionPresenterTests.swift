import Testing
import Foundation
@testable import CaptionDomain

private func source(_ id: String, seg: String, rev: Int, text: String, final: Bool) -> CaptionEvent {
    CaptionEvent(type: final ? .sourceFinal : .sourceReplace, sessionID: "s", laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: id, segmentID: seg, revision: rev, text: text, isFinal: final)
}

@Suite("Caption presenter (stability presets)")
struct CaptionPresenterTests {
    /// Replays word-by-word partials at 100 ms and counts how many distinct texts each preset
    /// puts on screen. Final text must be identical; repaint count must fall with the dwell.
    private func replay(dwellMs: Int) -> (shown: [String], finalText: String?) {
        var reducer = CaptionReducer(sessionID: "s")
        var presenter = CaptionPresenter(dwellNs: Int64(dwellMs) * 1_000_000)
        var shown: [String] = []
        var now: Int64 = 0
        let words = ["Please", "do", "not", "restart", "the", "server", "yet."]
        var text: [String] = []
        for (i, w) in words.enumerated() {
            text.append(w)
            _ = reducer.apply(source("e\(i)", seg: "s1", rev: i + 1, text: text.joined(separator: " "), final: false))
            var r = presenter.present(reducer.snapshot, nowNs: now)
            if let t = r.snapshot.segments.first?.sourceText, shown.last != t { shown.append(t) }
            // Advance 100 ms in 25 ms ticks, re-presenting when the presenter asked for it.
            for _ in 0..<4 {
                now += 25_000_000
                if let next = r.nextCheckNs, now >= next {
                    r = presenter.present(reducer.snapshot, nowNs: now)
                    if let t = r.snapshot.segments.first?.sourceText, shown.last != t { shown.append(t) }
                }
            }
        }
        _ = reducer.apply(source("final", seg: "s1", rev: 8, text: "Please do not restart the server yet.", final: true))
        let r = presenter.present(reducer.snapshot, nowNs: now)
        if let t = r.snapshot.segments.first?.sourceText, shown.last != t { shown.append(t) }
        return (shown, r.snapshot.segments.first?.sourceText)
    }

    @Test("Same replay: identical final text, fewer repaints with a longer dwell")
    func dwellReducesRepaints() {
        let responsive = replay(dwellMs: 100)
        let balanced = replay(dwellMs: 220)
        let steady = replay(dwellMs: 450)
        #expect(responsive.finalText == "Please do not restart the server yet.")
        #expect(balanced.finalText == responsive.finalText)
        #expect(steady.finalText == responsive.finalText)
        #expect(responsive.shown.count == 7, "\(responsive.shown)")
        #expect(balanced.shown.count < responsive.shown.count, "\(balanced.shown)")
        #expect(steady.shown.count < balanced.shown.count, "\(steady.shown)")
        #expect(steady.shown.last == steady.finalText)
    }

    @Test("Finals and new sentences are never delayed")
    func finalsImmediate() {
        var reducer = CaptionReducer(sessionID: "s")
        var presenter = CaptionPresenter(dwellNs: 1_000_000_000)
        _ = reducer.apply(source("a", seg: "s1", rev: 1, text: "Hello", final: false))
        _ = presenter.present(reducer.snapshot, nowNs: 0)
        _ = reducer.apply(source("b", seg: "s1", rev: 2, text: "Hello there", final: false))
        var r = presenter.present(reducer.snapshot, nowNs: 10_000_000)
        #expect(r.snapshot.segments.first?.sourceText == "Hello", "held during dwell")
        #expect(r.nextCheckNs == 1_000_000_000)
        _ = reducer.apply(source("c", seg: "s1", rev: 3, text: "Hello there.", final: true))
        r = presenter.present(reducer.snapshot, nowNs: 20_000_000)
        #expect(r.snapshot.segments.first?.sourceText == "Hello there.", "final shown at once")
        #expect(r.nextCheckNs == nil)
        _ = reducer.apply(source("d", seg: "s2", rev: 1, text: "Next", final: false))
        r = presenter.present(reducer.snapshot, nowNs: 30_000_000)
        #expect(r.snapshot.segments.last?.sourceText == "Next", "new sentence shown at once")
    }

    @Test("Zero dwell is a passthrough")
    func zeroDwell() {
        var reducer = CaptionReducer(sessionID: "s")
        var presenter = CaptionPresenter(dwellNs: 0)
        _ = reducer.apply(source("a", seg: "s1", rev: 1, text: "A", final: false))
        _ = presenter.present(reducer.snapshot, nowNs: 0)
        _ = reducer.apply(source("b", seg: "s1", rev: 2, text: "A B", final: false))
        let r = presenter.present(reducer.snapshot, nowNs: 1)
        #expect(r.snapshot == reducer.snapshot)
    }
}

@Suite("CaptionReducer validation and freezing")
struct CaptionReducerHardeningTests {
    @Test("B16: inverted or negative time ranges, negative revisions and missing fields are dropped before any state changes")
    func malformedDropped() {
        var r = CaptionReducer(sessionID: "s")
        var gap = CaptionEvent(type: .laneGap, sessionID: "s", laneID: "remote", captureEpoch: 1, providerEpoch: 7, eventID: "g")
        gap.startNs = 2_000_000_000
        gap.endNs = 1_000_000_000
        #expect(r.apply(gap) == [.dropped(eventID: "g", reason: .malformed)])
        #expect(r.snapshot.items.isEmpty)
        #expect(r.snapshot.activeProviderEpochs["remote"] == nil, "a malformed event must not register an epoch")
        var neg = source("n", seg: "s1", rev: -1, text: "x", final: false)
        neg.startNs = -5
        #expect(r.apply(neg) == [.dropped(eventID: "n", reason: .malformed)])
        let noSeg = CaptionEvent(type: .sourceFinal, sessionID: "s", laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: "m", segmentID: "", revision: 1, text: "x")
        #expect(r.apply(noSeg) == [.dropped(eventID: "m", reason: .malformed)])
        let emptyRefs = CaptionEvent(type: .translationFinal, sessionID: "s", laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: "t", text: "x", sourceRefs: [])
        #expect(r.apply(emptyRefs) == [.dropped(eventID: "t", reason: .malformed)])
        #expect(r.malformedCount == 4)
        // The same event id is still accepted once it is well formed: the dedup cache was not touched.
        var good = gap
        good.endNs = 3_000_000_000
        #expect(r.apply(good) == [.gapRecorded("gap/remote/g")])
    }

    @Test("Over-long text is truncated, not dropped")
    func longText() {
        var r = CaptionReducer(sessionID: "s")
        r.maxTextLength = 10
        _ = r.apply(source("a", seg: "s1", rev: 1, text: String(repeating: "x", count: 100), final: true))
        #expect(r.snapshot.segments.first?.sourceText.count == 11)
        #expect(r.snapshot.segments.first?.sourceText.hasSuffix("…") == true)
    }

    @Test("B05: freezeOpenSegments marks previews and untranslated finals incomplete, leaves finals alone, is idempotent")
    func freezeOpen() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(source("a", seg: "s1", rev: 1, text: "Done.", final: true))
        _ = r.apply(CaptionEvent(type: .translationFinal, sessionID: "s", laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: "ta", text: "完成。", isFinal: true, translationID: "t1", sourceRefs: [SourceRef(segmentID: "s1", revision: 1)]))
        _ = r.apply(source("b", seg: "s2", rev: 1, text: "Final but untranslated.", final: true))
        _ = r.apply(source("c", seg: "s3", rev: 2, text: "Still par", final: false))
        let effects = r.freezeOpenSegments(reason: "stopped")
        #expect(effects.count == 2)
        let segs = r.snapshot.segments
        #expect(segs[0].presentationState == .final && !segs[0].isIncomplete)
        #expect(segs[1].presentationState == .frozen && segs[1].incompleteReason == "stopped")
        #expect(segs[2].presentationState == .frozen && segs[2].incompleteReason == "stopped")
        #expect(segs[2].sourceText == "Still par")
        #expect(r.freezeOpenSegments(reason: "again").isEmpty)
        // A late partial for the frozen segment is refused.
        #expect(r.apply(source("d", seg: "s3", rev: 3, text: "Still partial", final: false)) == [.dropped(eventID: "d", reason: .finalizedSegment)])
    }

    @Test("Epoch advance marks the frozen partial incomplete too")
    func epochFreezeIncomplete() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(source("a", seg: "s1", rev: 1, text: "partial", final: false))
        var next = source("b", seg: "s2", rev: 1, text: "after", final: true)
        next.providerEpoch = 2
        _ = r.apply(next)
        #expect(r.snapshot.segment(id: "remote/1/s1")?.isIncomplete == true)
        #expect(r.snapshot.segment(id: "remote/2/s2")?.isIncomplete == false)
    }
}
