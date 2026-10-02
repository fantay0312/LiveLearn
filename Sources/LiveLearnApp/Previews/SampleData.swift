import Foundation
import AudioDomain
import CaptionDomain
import ProviderAdapters
import SessionDomain

/// Realistic snapshots for design previews, built through the real reducer so the rows carry
/// the same states the live app produces.
enum SampleData {
    static func runningSnapshot(dual: Bool = false, includeGap: Bool = true) -> SessionSnapshot {
        let sessionID = "preview"
        var r = CaptionReducer(sessionID: sessionID)
        var n = 0
        func id() -> String { n += 1; return "p\(n)" }
        func src(_ lane: String, _ seg: String, _ text: String, start: Int64, end: Int64, final: Bool = true, rev: Int = 3) {
            var e = CaptionEvent(type: final ? .sourceFinal : .sourceReplace, sessionID: sessionID, laneID: lane, captureEpoch: 1, providerEpoch: 1, eventID: id())
            e.segmentID = seg; e.revision = rev; e.text = text; e.isFinal = final
            e.startNs = start * 1_000_000; e.endNs = end * 1_000_000; e.language = lane == "mic" ? "zh-Hans" : "en"; e.timingQuality = .segment
            _ = r.apply(e)
        }
        func tr(_ lane: String, _ seg: String, _ text: String, rev: Int = 3) {
            var e = CaptionEvent(type: .translationFinal, sessionID: sessionID, laneID: lane, captureEpoch: 1, providerEpoch: 1, eventID: id())
            e.translationID = "t-\(seg)"; e.sourceRefs = [SourceRef(segmentID: seg, revision: rev)]; e.text = text; e.isFinal = true
            _ = r.apply(e)
        }
        func gap(_ lane: String, start: Int64, end: Int64, reason: String) {
            var e = CaptionEvent(type: .laneGap, sessionID: sessionID, laneID: lane, captureEpoch: 1, providerEpoch: 1, eventID: id())
            e.startNs = start * 1_000_000; e.endNs = end * 1_000_000; e.gapReason = reason
            _ = r.apply(e)
        }

        src("remote", "s1", "Before we touch anything in production, let's look at what the logs are actually saying.", start: 12_400, end: 17_900)
        tr("remote", "s1", "在动生产环境之前，我们先看看日志到底在说什么。")
        src("remote", "s2", "Please do not restart the server yet.", start: 18_600, end: 20_900)
        tr("remote", "s2", "请先不要重启服务器。")
        if dual {
            src("mic", "m1", "日志在哪里可以看到？", start: 21_500, end: 23_200)
            tr("mic", "m1", "Where can I see the logs?")
        }
        src("remote", "s3", "The retry storm you are seeing is a symptom, not the cause.", start: 24_100, end: 28_300)
        tr("remote", "s3", "你看到的重试风暴是症状，不是原因。")
        if includeGap { gap("remote", start: 28_300, end: 30_600, reason: "network") }
        src("remote", "s4", "If we roll back now, we lose the evidence we need for the postmortem.", start: 30_600, end: 35_200)
        tr("remote", "s4", "如果现在回滚，我们会失去复盘所需的证据。")
        if dual {
            src("mic", "m2", "我们这边的网关也在报超时。", start: 35_900, end: 38_100)
            tr("mic", "m2", "Our gateway is reporting timeouts as well.")
        }
        src("remote", "s5", "So the plan is: freeze deploys, capture the traces, then decide.", start: 38_800, end: 43_000)
        tr("remote", "s5", "所以计划是：冻结发布，抓取链路追踪，然后再决定。")
        // Current, still forming: final source, translation pending.
        src("remote", "s6", "Any questions before we split into two", start: 44_200, end: 46_100, final: false, rev: 7)

        var snap = SessionSnapshot(sessionID: sessionID, state: .running, captions: r.snapshot, lanes: [], startedAtHostNs: 0, elapsedNs: 46_400_000_000, failure: nil, detail: nil)
        let remote = LaneStatus(
            id: "remote",
            configuration: LaneConfiguration(id: "remote", source: AudioSourceDescriptor(kind: .application, bundleIdentifier: "com.apple.Safari", displayName: "Safari"), sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: EngineBlueprint.providerID),
            capture: CaptureHealth(laneID: "remote", captureEpoch: 1, state: .capturing, callbackCount: 4_312, lastAudioNs: 46_300_000_000, level: 0.11, peak: 0.4, format: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 2), queuedNs: 120_000_000, droppedNs: 0),
            providerName: "Apple 识别 · Apple 翻译", providerEpoch: 1, providerLink: .connected, reconnectAttempts: 0, lastError: nil, isUploading: true, dataDestination: "本地，不联网", sentWatermarkNs: 46_200_000_000, capturedWatermarkNs: 46_300_000_000)
        snap.lanes = [remote]
        if dual {
            let mic = LaneStatus(
                id: "mic",
                configuration: LaneConfiguration(id: "mic", source: AudioSourceDescriptor(kind: .microphone, deviceUID: "builtin", displayName: "MacBook Pro麦克风"), sourceLanguage: "zh-Hans", targetLanguage: "en", providerID: EngineBlueprint.providerID),
                capture: CaptureHealth(laneID: "mic", captureEpoch: 1, state: .waitingForAudio, callbackCount: 2_150, lastAudioNs: 38_100_000_000, level: 0.0, peak: 0.0, format: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1), queuedNs: 0, droppedNs: 0),
                providerName: "Apple 识别 · Apple 翻译", providerEpoch: 1, providerLink: .connected, reconnectAttempts: 0, lastError: nil, isUploading: true, dataDestination: "本地，不联网", sentWatermarkNs: 46_300_000_000, capturedWatermarkNs: 46_300_000_000)
            snap.lanes.append(mic)
        }
        return snap
    }

    static func awaitingTranslationSnapshot() -> SessionSnapshot {
        var snap = runningSnapshot()
        var r = CaptionReducer(sessionID: "preview")
        for item in snap.captions.items {
            _ = item
        }
        // Rebuild with the last segment finalized but untranslated.
        var events: [CaptionEvent] = []
        var n = 100
        func id() -> String { n += 1; return "q\(n)" }
        for seg in snap.captions.segments where seg.id != "remote/1/s6" {
            var e = CaptionEvent(type: .sourceFinal, sessionID: "preview", laneID: seg.laneID, captureEpoch: 1, providerEpoch: 1, eventID: id())
            e.segmentID = seg.providerSegmentID; e.revision = seg.sourceRevision; e.text = seg.sourceText; e.isFinal = true; e.startNs = seg.startNs; e.endNs = seg.endNs; e.timingQuality = .segment
            events.append(e)
            if let t = seg.translation {
                var te = CaptionEvent(type: .translationFinal, sessionID: "preview", laneID: seg.laneID, captureEpoch: 1, providerEpoch: 1, eventID: id())
                te.translationID = t.id; te.sourceRefs = [SourceRef(segmentID: seg.providerSegmentID, revision: seg.sourceRevision)]; te.text = t.text; te.isFinal = true
                events.append(te)
            }
        }
        var last = CaptionEvent(type: .sourceFinal, sessionID: "preview", laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: id())
        last.segmentID = "s6"; last.revision = 8; last.text = "Any questions before we split into two groups?"; last.isFinal = true; last.startNs = 44_200_000_000; last.endNs = 47_100_000_000; last.timingQuality = .segment
        events.append(last)
        for e in events { _ = r.apply(e) }
        snap.captions = r.snapshot
        return snap
    }
}
