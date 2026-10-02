import Testing
import Foundation
@testable import SessionStorage
@testable import SessionDomain
@testable import CaptionDomain
@testable import AudioDomain

private func sampleSnapshot(dual: Bool = false, unfinishedTail: Bool = true) -> SessionSnapshot {
    let sid = "sess/1"
    var r = CaptionReducer(sessionID: sid)
    var n = 0
    func id() -> String { n += 1; return "e\(n)" }
    func src(_ lane: String, _ seg: String, _ text: String, _ s: Int64, _ e: Int64, final: Bool = true) {
        var ev = CaptionEvent(type: final ? .sourceFinal : .sourceReplace, sessionID: sid, laneID: lane, captureEpoch: 1, providerEpoch: 1, eventID: id())
        ev.segmentID = seg; ev.revision = 1; ev.text = text; ev.isFinal = final; ev.startNs = s * 1_000_000; ev.endNs = e * 1_000_000; ev.language = lane == "mic" ? "zh-Hans" : "en"
        _ = r.apply(ev)
    }
    func tr(_ lane: String, _ seg: String, _ text: String) {
        var ev = CaptionEvent(type: .translationFinal, sessionID: sid, laneID: lane, captureEpoch: 1, providerEpoch: 1, eventID: id())
        ev.translationID = "t-\(seg)"; ev.sourceRefs = [SourceRef(segmentID: seg, revision: 1)]; ev.text = text; ev.isFinal = true
        _ = r.apply(ev)
    }
    src("remote", "s1", "Please do not restart the server yet.", 1_200, 3_900)
    tr("remote", "s1", "请先不要重启服务器。")
    var gap = CaptionEvent(type: .laneGap, sessionID: sid, laneID: "remote", captureEpoch: 1, providerEpoch: 1, eventID: id())
    gap.startNs = 3_900_000_000; gap.endNs = 6_200_000_000; gap.gapReason = GapReason.paused.rawValue
    _ = r.apply(gap)
    // Overlapping with the previous cue on purpose and shorter than the minimum duration.
    src("remote", "s2", "Thank you.", 3_800, 3_900)
    tr("remote", "s2", "谢谢。")
    if dual {
        src("mic", "m1", "日志在哪里可以看到？", 6_500, 8_000)
        tr("mic", "m1", "Where can I see the logs?")
    }
    if unfinishedTail {
        src("remote", "s3", "If we roll back", 9_000, 10_000, final: false)
        _ = r.freezeOpenSegments(reason: "停止时这句没有定稿")
    }
    var lanes = [LaneStatus(id: "remote", configuration: LaneConfiguration(id: "remote", source: AudioSourceDescriptor(kind: .application, bundleIdentifier: "com.apple.Safari", displayName: "Safari"), sourceLanguage: "en", targetLanguage: "zh-Hans", providerID: "apple.local"), capture: CaptureHealth(laneID: "remote", state: .stopped), providerName: "本机引擎", providerEpoch: 1, providerLink: .closed, reconnectAttempts: 0, lastError: nil, isUploading: false, dataDestination: "本机处理，不联网", sentWatermarkNs: 0, capturedWatermarkNs: 0)]
    if dual {
        lanes.append(LaneStatus(id: "mic", configuration: LaneConfiguration(id: "mic", source: AudioSourceDescriptor(kind: .microphone, deviceUID: "builtin", displayName: "MacBook Pro麦克风"), sourceLanguage: "zh-Hans", targetLanguage: "en", providerID: "apple.local"), capture: CaptureHealth(laneID: "mic", state: .stopped), providerName: "本机引擎", providerEpoch: 1, providerLink: .closed, reconnectAttempts: 0, lastError: nil, isUploading: false, dataDestination: "本机处理，不联网", sentWatermarkNs: 0, capturedWatermarkNs: 0))
    }
    return SessionSnapshot(sessionID: sid, state: .completed, captions: r.snapshot, lanes: lanes, startedAtHostNs: 0, elapsedNs: 10_500_000_000, failure: nil, detail: nil)
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearnStoreTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Session archive, store and export")
struct SessionStorageTests {

    @Test("Archive round-trips through the store and reopens as a stopped snapshot")
    func roundTrip() throws {
        let store = SessionStore(directory: tempDir())
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let archive = SessionArchive(snapshot: sampleSnapshot(dual: true), title: "Safari · 英语 → 中文", startedAt: started, outcome: .completed, appVersion: "0.1.0")
        let url = try store.save(archive)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let loaded = try store.load(id: archive.id)
        #expect(loaded == archive)
        #expect(loaded.segmentCount == 3 && loaded.incompleteCount == 1 && loaded.gapCount == 1)
        let snap = loaded.displaySnapshot()
        #expect(snap.state == .completed)
        #expect(snap.lanes.map(\.id) == ["remote", "mic"])
        #expect(snap.lanes[0].configuration.source.displayName == "Safari")
        #expect(snap.lanes[0].capture.state == .stopped && snap.lanes[0].providerLink == .closed)
        #expect(snap.captions.segments.count == 4)
        #expect(snap.elapsedNs == 10_500_000_000)
        let all = store.loadAll()
        #expect(all.archives.map(\.id) == [archive.id] && all.problems.isEmpty)
        try store.delete(id: archive.id)
        #expect(!store.exists(id: archive.id))
        #expect(throws: SessionStoreError.self) { try store.load(id: archive.id) }
    }

    @Test("A leftover checkpoint becomes an interrupted record on the next launch; unreadable files are reported, not fatal")
    func checkpointRecovery() throws {
        let dir = tempDir()
        let store = SessionStore(directory: dir)
        let running = SessionArchive(snapshot: sampleSnapshot(unfinishedTail: false), title: "t", startedAt: Date(), outcome: .completed, appVersion: "dev")
        try store.writeCheckpoint(running)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let recovered = store.recoverCheckpoints()
        #expect(recovered.count == 1)
        #expect(recovered[0].outcome == .interrupted && recovered[0].endedAt == nil)
        #expect(store.exists(id: running.id))
        #expect(!FileManager.default.fileExists(atPath: store.checkpointURL(for: running.id).path))
        let all = store.loadAll()
        #expect(all.archives.count == 1 && all.problems.count == 1)
        // Second launch: nothing left to recover; a checkpoint for an existing record is dropped.
        try store.writeCheckpoint(running)
        #expect(store.recoverCheckpoints().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.checkpointURL(for: running.id).path))
        #expect(store.loadAll().archives.first?.outcome == .interrupted)
    }

    @Test("Text and Markdown carry header, timestamps, lane tags, the unfinished marker and gaps")
    func textAndMarkdown() throws {
        let archive = SessionArchive(snapshot: sampleSnapshot(dual: true), title: "Safari · 英语 → 中文", startedAt: Date(timeIntervalSince1970: 1_800_000_000), outcome: .completed, appVersion: "0.1.0")
        let txt = try TranscriptExporter.render(archive, format: .text)
        #expect(txt.hasPrefix("Safari · 英语 → 中文\n"))
        #expect(txt.contains("[00:01] [Safari] 请先不要重启服务器。\n    Please do not restart the server yet."))
        #expect(txt.contains("[00:03] —— 缺口 2.3 秒 · 已暂停"))
        #expect(txt.contains("[麦克风] Where can I see the logs?"))
        #expect(txt.contains("[00:09] [Safari] [未完成] If we roll back"))
        #expect(txt.contains("时长 0:00:10 · 3 句（1 句未完成） · 缺口 1 处"))
        let md = try TranscriptExporter.render(archive, format: .markdown)
        #expect(md.hasPrefix("# Safari · 英语 → 中文\n"))
        #expect(md.contains("**00:01** · Safari  \n请先不要重启服务器。  \n*Please do not restart the server yet.*"))
        #expect(md.contains("> 缺口 2.3 秒 · 已暂停"))
        #expect(md.contains("· 未完成"))
    }

    @Test("SRT / VTT cues are ordered, non-overlapping, at least 600 ms, and skip gaps")
    func subtitles() throws {
        let archive = SessionArchive(snapshot: sampleSnapshot(), title: "t", startedAt: Date(), outcome: .completed, appVersion: "dev")
        let srt = try TranscriptExporter.render(archive, format: .srt)
        let vtt = try TranscriptExporter.render(archive, format: .vtt)
        #expect(srt.hasPrefix("1\n00:00:01,200 --> 00:00:03,900\n请先不要重启服务器。\nPlease do not restart the server yet.\n\n2\n"))
        // s2 started at 3.8 s (inside cue 1) and lasted 100 ms: pushed to 3.9 s and stretched to 600 ms.
        #expect(srt.contains("2\n00:00:03,900 --> 00:00:04,500\n谢谢。\nThank you.\n"))
        #expect(srt.contains("3\n00:00:09,000 --> 00:00:10,000\nIf we roll back（未完成）\n"))
        #expect(!srt.contains("缺口"))
        #expect(vtt.hasPrefix("WEBVTT\n\nNOTE t · "))
        #expect(vtt.contains("00:00:01.200 --> 00:00:03.900"))
        let cues = TranscriptExporter.cues(archive)
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(b.startNs >= a.endNs) }
        for c in cues { #expect(c.endNs - c.startNs >= 600_000_000) }
    }

    @Test("Empty sessions refuse to export; file names are safe and keep Unicode")
    func emptyAndFileName() {
        let empty = SessionArchive(id: "x", title: "空", startedAt: Date(), endedAt: nil, durationNs: 0, outcome: .completed, failure: nil, appVersion: "dev", lanes: [], items: [])
        #expect(throws: ExportError.empty) { try TranscriptExporter.render(empty, format: .srt) }
        let archive = SessionArchive(id: "y", title: "  Safari · 英语 → 中文 / 会议:2  ", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, durationNs: 0, outcome: .completed, failure: nil, appVersion: "dev", lanes: [], items: [])
        let name = TranscriptExporter.suggestedFileName(archive, format: .vtt)
        #expect(name.hasPrefix("LiveLearn 2027-"))
        #expect(name.hasSuffix(" Safari · 英语 → 中文 - 会议-2.vtt"))
        #expect(!name.contains("/") && !name.contains(":"))
    }
}
