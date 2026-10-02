import Testing
import Foundation
@testable import CaptionDomain
@testable import ProviderAdapters

private func ev(_ type: CaptionEvent.Kind, lane: String = "remote", epoch: UInt64 = 1, id: String, seg: String? = nil, rev: Int? = nil, text: String? = nil, final: Bool? = nil, refs: [SourceRef]? = nil, start: Int64? = nil, end: Int64? = nil, session: String = "s") -> CaptionEvent {
    CaptionEvent(type: type, sessionID: session, laneID: lane, captureEpoch: 1, providerEpoch: epoch, eventID: id, segmentID: seg, revision: rev, startNs: start, endNs: end, text: text, isFinal: final, translationID: refs == nil ? nil : "tr-\(id)", sourceRefs: refs)
}

@Suite("CaptionReducer invariants")
struct CaptionReducerTests {

    @Test("T07: two identical sentences are both kept (no text dedup)")
    func duplicateSentencesKept() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceFinal, id: "e1", seg: "s1", rev: 1, text: "Thank you.", final: true))
        _ = r.apply(ev(.sourceFinal, id: "e2", seg: "s2", rev: 1, text: "Thank you.", final: true))
        #expect(r.snapshot.segments.count == 2)
        #expect(r.snapshot.segments.map(\.sourceText) == ["Thank you.", "Thank you."])
    }

    @Test("Same eventID delivered twice is idempotent")
    func duplicateEventIgnored() {
        var r = CaptionReducer(sessionID: "s")
        let e = ev(.sourceFinal, id: "e1", seg: "s1", rev: 1, text: "Thank you.", final: true)
        let first = r.apply(e)
        let second = r.apply(e)
        #expect(first == [.segmentCreated("remote/1/s1")])
        #expect(second == [.dropped(eventID: "e1", reason: .duplicateEvent)])
        #expect(r.snapshot.segments.count == 1)
    }

    @Test("T08: late translation for revision 1 does not overwrite revision 2 translation")
    func lateTranslationDoesNotOverwrite() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceReplace, id: "e1", seg: "s3", rev: 1, text: "We lose the evidence for the post", final: false))
        _ = r.apply(ev(.sourceFinal, id: "e2", seg: "s3", rev: 2, text: "We lose the evidence for the postmortem.", final: true))
        _ = r.apply(ev(.translationFinal, id: "e3", text: "我们会失去复盘的证据。", final: true, refs: [SourceRef(segmentID: "s3", revision: 2)]))
        let effects = r.apply(ev(.translationReplace, id: "e4", text: "我们失去了给帖子的证据", final: false, refs: [SourceRef(segmentID: "s3", revision: 1)]))
        #expect(effects == [.dropped(eventID: "e4", reason: .staleTranslation)])
        let seg = r.snapshot.segment(id: "remote/1/s3")!
        #expect(seg.translation?.text == "我们会失去复盘的证据。")
        #expect(seg.presentationState == .final)
    }

    @Test("Provisional translation for an older revision is accepted when nothing newer exists, marked stale")
    func provisionalStaleTranslation() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceReplace, id: "e1", seg: "s1", rev: 1, text: "Please do not", final: false))
        _ = r.apply(ev(.sourceReplace, id: "e2", seg: "s1", rev: 2, text: "Please do not restart", final: false))
        _ = r.apply(ev(.translationReplace, id: "e3", text: "请不要", final: false, refs: [SourceRef(segmentID: "s1", revision: 1)]))
        let seg = r.snapshot.segment(id: "remote/1/s1")!
        #expect(seg.translation?.isStale == true)
        #expect(seg.presentationState == .preview)
        _ = r.apply(ev(.translationReplace, id: "e4", text: "请不要重启", final: false, refs: [SourceRef(segmentID: "s1", revision: 2)]))
        #expect(r.snapshot.segment(id: "remote/1/s1")!.translation?.isStale == false)
    }

    @Test("T09: events from an older provider epoch are dropped after reconnect; old segments freeze")
    func staleEpochIgnored() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceReplace, epoch: 1, id: "e1", seg: "s1", rev: 1, text: "partial", final: false))
        let eff = r.apply(ev(.sourceFinal, epoch: 2, id: "e2", seg: "s2", rev: 1, text: "After reconnect", final: true))
        #expect(eff.contains(.laneFrozen(lane: "remote", providerEpoch: 2)))
        #expect(r.snapshot.segment(id: "remote/1/s1")?.presentationState == .frozen)
        let stale = r.apply(ev(.sourceReplace, epoch: 1, id: "e3", seg: "s1", rev: 2, text: "SHOULD NOT APPEAR", final: false))
        #expect(stale == [.dropped(eventID: "e3", reason: .staleProviderEpoch)])
        #expect(r.snapshot.segment(id: "remote/1/s1")?.sourceText == "partial")
        #expect(r.snapshot.segments.count == 2)
    }

    @Test("Finalized source is not rewritten by a later partial; corrections are explicit and kept in history")
    func finalNotRewritten() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceFinal, id: "e1", seg: "s1", rev: 3, text: "Final text.", final: true))
        let late = r.apply(ev(.sourceReplace, id: "e2", seg: "s1", rev: 4, text: "Final text again", final: false))
        #expect(late == [.dropped(eventID: "e2", reason: .finalizedSegment)])
        _ = r.apply(ev(.sourceCorrection, id: "e3", seg: "s1", rev: 4, text: "Final text, corrected.", final: true))
        let seg = r.snapshot.segment(id: "remote/1/s1")!
        #expect(seg.sourceText == "Final text, corrected.")
        #expect(seg.corrected)
        #expect(seg.history == ["Final text."])
    }

    @Test("Lanes are isolated: identical sentence on both lanes stays on both")
    func lanesIsolated() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceFinal, lane: "mic", id: "a1", seg: "s1", rev: 1, text: "Hello", final: true))
        _ = r.apply(ev(.sourceFinal, lane: "remote", id: "b1", seg: "s1", rev: 1, text: "Hello", final: true))
        #expect(r.snapshot.segments(lane: "mic").count == 1)
        #expect(r.snapshot.segments(lane: "remote").count == 1)
    }

    @Test("Other session events are rejected")
    func otherSession() {
        var r = CaptionReducer(sessionID: "s")
        let eff = r.apply(ev(.sourceFinal, id: "x", seg: "s1", rev: 1, text: "Hi", final: true, session: "other"))
        #expect(eff == [.dropped(eventID: "x", reason: .otherSession)])
    }

    @Test("Translation final before source final shows but does not lock")
    func translationBeforeSourceFinal() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceReplace, id: "e1", seg: "s1", rev: 1, text: "So the plan is", final: false))
        _ = r.apply(ev(.translationFinal, id: "e2", text: "所以计划是", final: true, refs: [SourceRef(segmentID: "s1", revision: 1)]))
        #expect(r.snapshot.segment(id: "remote/1/s1")!.presentationState == .preview)
        _ = r.apply(ev(.sourceFinal, id: "e3", seg: "s1", rev: 1, text: "So the plan is", final: true))
        #expect(r.snapshot.segment(id: "remote/1/s1")!.presentationState == .final)
    }

    @Test("Gap is recorded in order, never merged away")
    func gapRecorded() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceFinal, id: "e1", seg: "s1", rev: 1, text: "A", final: true))
        var g = ev(.laneGap, id: "g1", start: 1_000_000_000, end: 3_300_000_000)
        g.gapReason = "network"
        _ = r.apply(g)
        _ = r.apply(ev(.sourceFinal, id: "e2", seg: "s2", rev: 1, text: "B", final: true))
        #expect(r.snapshot.items.count == 3)
        if case .gap(let gap) = r.snapshot.items[1] {
            #expect(gap.durationNs == 2_300_000_000)
        } else {
            Issue.record("expected a gap at index 1")
        }
    }

    @Test("Multi-segment translation attaches to the first ref and marks the rest merged")
    func groupTranslation() {
        var r = CaptionReducer(sessionID: "s")
        _ = r.apply(ev(.sourceFinal, id: "e1", seg: "s1", rev: 1, text: "Freeze deploys,", final: true))
        _ = r.apply(ev(.sourceFinal, id: "e2", seg: "s2", rev: 1, text: "capture the traces.", final: true))
        _ = r.apply(ev(.translationFinal, id: "e3", text: "冻结发布，抓取链路追踪。", final: true, refs: [SourceRef(segmentID: "s1", revision: 1), SourceRef(segmentID: "s2", revision: 1)]))
        let a = r.snapshot.segment(id: "remote/1/s1")!
        let b = r.snapshot.segment(id: "remote/1/s2")!
        #expect(a.translation?.coveredSegmentIDs.count == 2)
        #expect(a.translation?.timingQuality == .estimated)
        #expect(b.mergedIntoTranslation == a.translation?.id)
    }

    @Test("Edge-case fixture replays deterministically through the reducer")
    func fixtureReplay() {
        var r = CaptionReducer(sessionID: "s")
        var epoch: UInt64 = 1
        var prev: UInt64? = nil
        var counter = 0
        for step in FakeScript.edgeCases.steps {
            counter += 1
            switch step {
            case .source(_, let seg, let rev, let text, let s, let e, let final, let id):
                var x = ev(final ? .sourceFinal : .sourceReplace, epoch: epoch, id: id ?? "auto-\(counter)", seg: seg, rev: rev, text: text, final: final)
                x.startNs = Int64(s) * 1_000_000
                x.endNs = Int64(e) * 1_000_000
                _ = r.apply(x)
            case .translation(_, _, let refs, let text, let final, let id):
                _ = r.apply(ev(final ? .translationFinal : .translationReplace, epoch: epoch, id: id ?? "auto-\(counter)", text: text, final: final, refs: refs))
            case .gap(_, let s, let e, let reason):
                var g = ev(.laneGap, epoch: epoch, id: "gap-\(counter)", start: Int64(s) * 1_000_000, end: Int64(e) * 1_000_000)
                g.gapReason = reason
                _ = r.apply(g)
            case .disconnect:
                prev = epoch
                epoch += 1
            case .staleFromPreviousEpoch(_, let seg, let rev, let text):
                _ = r.apply(ev(.sourceReplace, epoch: prev ?? epoch, id: "stale-\(counter)", seg: seg, rev: rev, text: text, final: false))
            case .waitForVoice, .end:
                break
            }
        }
        let segs = r.snapshot.segments
        #expect(segs.count == 4)
        #expect(segs[0].sourceText == "Thank you." && segs[1].sourceText == "Thank you.")
        #expect(segs[2].translation?.text == "我们会失去复盘的证据。")
        #expect(segs[2].presentationState == .final || segs[2].presentationState == .frozen)
        #expect(!segs.contains { $0.sourceText.contains("SHOULD NOT APPEAR") })
        #expect(segs[3].translation?.text == "有问题吗？")
        #expect(r.snapshot.items.contains { if case .gap = $0 { return true } else { return false } })
    }

    @Test("Event JSON round-trips with the shared contract field names")
    func jsonRoundTrip() throws {
        var e = ev(.sourceReplace, id: "provider3-message17", seg: "segment-008", rev: 2, text: "Please do not restart the server.", final: false, start: 4_100_000_000, end: 6_300_000_000)
        e.language = "en"
        e.timingQuality = .segment
        let data = try JSONEncoder().encode(e)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(obj["type"] as? String == "source.replace")
        #expect(obj["schemaVersion"] as? Int == 1)
        #expect(obj["providerEpoch"] as? Int == 1)
        let back = try JSONDecoder().decode(CaptionEvent.self, from: data)
        #expect(back == e)
    }
}
