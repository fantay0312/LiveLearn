import Testing
import Foundation
import CaptionDomain
import EngineKit
import SessionStorage
@testable import LiveLearnApp

@MainActor
struct VocabularyCorrectionReviewTests {
    @Test func manuallySavedTerminalRecordKeepsReviewsAcrossReload() async throws {
        let suite = "LiveLearn.testing.saved-review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let settings = AppSettings(defaults: defaults)
        settings.autoSaveSessions = false
        settings.hotWords = ["飞书"]
        let store = SessionStore(directory: directory)
        let model = AppModel(settings: settings, store: store, credentials: .empty)
        var snap = SampleData.runningSnapshot()
        snap.state = .completed
        var segment = try #require(snap.captions.segments.first)
        segment.sourceText = "用飞鼠开会。"
        segment.sourceFinal = true
        segment.incompleteReason = nil
        segment.vocabularyCandidates = VocabularyCandidateGenerator(vocabulary: settings.hotWords).candidates(in: segment.sourceText)
        snap.captions.items = [.segment(segment)]
        model.receive(snap)
        model.save(try #require(model.records.first))
        #expect(model.records.first?.saved == true)
        // A terminal snapshot can be delivered again after manually saving.
        model.receive(snap)
        #expect(model.records.first?.saved == true)
        let candidate = try #require(segment.vocabularyCandidates?.first)
        #expect(await model.reviewVocabularyCandidate(sessionID: snap.sessionID, segmentID: segment.id,
            revision: segment.sourceRevision, candidate: candidate, confirm: true) == nil)
        #expect(model.records.first?.saved == true)
        let reloaded = try #require(store.loadAll().archives.first)
        #expect(reloaded.segments.first?.sourceText == "用飞书开会。")
        #expect(reloaded.segments.first?.originalRecognitionText == "用飞鼠开会。")
    }

    @Test func savedRecordWriteFailureLeavesDisplayedTextAndCandidateIntact() async throws {
        let suite = "LiveLearn.testing.failed-review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let preserved = directory.appendingPathExtension("preserved")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: preserved)
        }
        let settings = AppSettings(defaults: defaults)
        settings.hotWords = ["飞书"]
        let store = SessionStore(directory: directory)
        var snap = SampleData.runningSnapshot()
        snap.state = .completed
        var segment = try #require(snap.captions.segments.first)
        segment.sourceText = "用飞鼠开会。"; segment.sourceFinal = true; segment.incompleteReason = nil
        segment.vocabularyCandidates = VocabularyCandidateGenerator(vocabulary: settings.hotWords).candidates(in: segment.sourceText)
        snap.captions.items = [.segment(segment)]
        try store.save(SessionArchive(snapshot: snap, title: "Test", startedAt: Date(), outcome: .completed, appVersion: "test"))
        let model = AppModel(settings: settings, store: store, credentials: .empty)
        model.showRecord(try #require(model.records.first))
        try FileManager.default.moveItem(at: directory, to: preserved)
        try Data("blocks directory creation".utf8).write(to: directory)
        let candidate = try #require(segment.vocabularyCandidates?.first)
        let error = await model.reviewVocabularyCandidate(sessionID: snap.sessionID, segmentID: segment.id,
            revision: segment.sourceRevision, candidate: candidate, confirm: true)
        #expect(error?.contains("保存失败") == true)
        #expect(model.captions.segments.first?.sourceText == segment.sourceText)
        #expect(model.captions.segments.first?.vocabularyCandidates == segment.vocabularyCandidates)
    }

    @Test func reviewRejectsOtherSessionsAndRemovedTargetsAndNeverLearnsAliases() async throws {
        let suite = "LiveLearn.testing.review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.hotWords = ["LiveLearn", "飞书"]
        let text = "Open live lawn."
        var snap = SampleData.runningSnapshot()
        var segment = try #require(snap.captions.segments.first)
        segment.sourceText = text
        segment.sourceFinal = true
        segment.incompleteReason = nil
        segment.vocabularyCandidates = VocabularyCandidateGenerator(vocabulary: settings.hotWords).candidates(in: text)
        snap.captions.items = [.segment(segment)]
        let model = AppModel(settings: settings, preview: snap)
        let candidate = try #require(segment.vocabularyCandidates?.first)
        #expect(await model.reviewVocabularyCandidate(sessionID: "other", segmentID: segment.id, revision: segment.sourceRevision,
                                                      candidate: candidate, confirm: true) != nil)
        #expect(model.captions.segments.first?.sourceText == text)
        #expect(await model.reviewVocabularyCandidate(sessionID: snap.sessionID, segmentID: segment.id, revision: segment.sourceRevision,
                                                      candidate: candidate, confirm: true) == nil)
        #expect(model.captions.segments.first?.sourceText == "Open LiveLearn.")
        #expect(model.captions.segments.first?.history.last == text)
        #expect(settings.hotWords == ["LiveLearn", "飞书"] && settings.glossaryLines.isEmpty)
        #expect(await model.reviewVocabularyCandidate(sessionID: snap.sessionID, segmentID: segment.id, revision: segment.sourceRevision,
                                                      candidate: candidate, confirm: true) != nil)
        settings.hotWords = []
        let empty = AppModel(settings: settings, preview: snap)
        #expect(await empty.reviewVocabularyCandidate(sessionID: snap.sessionID, segmentID: segment.id, revision: segment.sourceRevision,
                                                      candidate: candidate, confirm: true) != nil)
        #expect(empty.captions.segments.first?.sourceText == text)
    }
}
