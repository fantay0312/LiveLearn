import Foundation
import Testing
import CaptionDomain
@testable import EngineKit

@Suite("Vocabulary mishearing candidates")
struct VocabularyCandidateTests {
    let generator = VocabularyCandidateGenerator(vocabulary: ["LiveLearn", "飞书", "WhisperKit", "Kubernetes"])

    @Test(arguments: [("Open live lawn.", "live lawn", "LiveLearn"),
                      ("我们用飞鼠开会。", "飞鼠", "飞书"),
                      ("Use whisper kid today.", "whisper kid", "WhisperKit"),
                      ("Deploy to Kubernets.", "Kubernets", "Kubernetes")])
    func retrievesFromUserVocabulary(example: (String, String, String)) throws {
        let (text, heard, word) = example
        let candidate = try #require(generator.candidates(in: text).first { $0.replacement == word })
        #expect(candidate.original == heard)
        #expect(candidate.applying(to: text) == text.replacingOccurrences(of: heard, with: word))
        #expect(VocabularyMatcher([VocabularyTerm(source: word, target: word)]).replacing(in: text) == text)
    }

    @Test func candidatesDoNotAssertMeaningAndNeverInventUserWords() {
        #expect(!generator.candidates(in: "树上有一只飞鼠。").isEmpty, "Even a homophone can be correct; the user decides")
        #expect(VocabularyCandidateGenerator(vocabulary: []).candidates(in: "Open live lawn. 用飞鼠。").isEmpty)
        #expect(VocabularyCandidateGenerator(vocabulary: ["OtherProduct"]).candidates(in: "Open live lawn.").isEmpty)
        #expect(generator.candidates(in: "We saw three birds and 42 trees.").isEmpty)
        #expect(generator.candidates(in: "LiveLearn 和飞书都已打开。").isEmpty)
    }

    @Test func guardsIdentifiersPunctuationShortWordsAndBounds() {
        for text in ["xlivelawnBuilder", "livelawn_v2", "livelawn42", "live\nlawn", "live.lawn"] {
            #expect(generator.candidates(in: text).isEmpty, "Do not span punctuation or an identifier: \(text)")
        }
        #expect(VocabularyCandidateGenerator(vocabulary: ["US", "API", "the"]).candidates(in: "us ape she").isEmpty)
        #expect(generator.candidates(in: String(repeating: "a", count: 4097)).isEmpty)
        let repeated = generator.candidates(in: String(repeating: "飞鼠。", count: 30))
        #expect(repeated.count == VocabularyCandidateGenerator.candidateLimit)
        #expect(Set(repeated.map(\.id)).count == repeated.count)
    }

    @Test func explicitConfirmationOnlyChangesOneOccurrenceAndRejectsStaleClicks() throws {
        let text = "👩🏽‍💻 打开 live lawn，再用飞鼠；飞鼠也可能是动物。"
        var event = CaptionEvent(type: .sourceFinal, sessionID: "s", laneID: "mic", captureEpoch: 1, providerEpoch: 1,
                                 eventID: "e", segmentID: "one", revision: 1, text: text, isFinal: true)
        event.vocabularyCandidates = generator.candidates(in: text)
        var reducer = CaptionReducer(sessionID: "s")
        _ = reducer.apply(event)
        var segment = try #require(reducer.snapshot.segments.first)
        let first = try #require(segment.vocabularyCandidates?.first { $0.replacement == "LiveLearn" })
        let untouched = segment
        let reviewResult0 = !segment.confirmVocabularyCorrection(first, revision: 0)
        #expect(reviewResult0)
        #expect(segment == untouched)
        let reviewResult1 = segment.confirmVocabularyCorrection(first, revision: 1)
        #expect(reviewResult1)
        #expect(segment.sourceText == "👩🏽‍💻 打开 LiveLearn，再用飞鼠；飞鼠也可能是动物。")
        #expect(segment.history == [text] && segment.corrected)
        let reviewResult2 = !segment.confirmVocabularyCorrection(first, revision: 1)
        #expect(reviewResult2)
        let chinese = try #require(segment.vocabularyCandidates?.first { $0.replacement == "飞书" })
        let reviewResult3 = segment.confirmVocabularyCorrection(chinese, revision: 2)
        #expect(reviewResult3)
        #expect(segment.sourceText == "👩🏽‍💻 打开 LiveLearn，再用飞书；飞鼠也可能是动物。")
        #expect(segment.history.count == 2)
        let remaining = try #require(segment.vocabularyCandidates?.first)
        let beforeDismiss = segment.sourceText
        let reviewResult4 = segment.dismissVocabularyCorrection(remaining, revision: 3)
        #expect(reviewResult4)
        #expect(segment.sourceText == beforeDismiss && segment.sourceRevision == 3)
        #expect(segment.vocabularyCandidates?.isEmpty == true)
    }

    @Test func archivesRoundTripAndLegacyMissingCandidatesDecode() throws {
        var e = CaptionEvent(type: .sourceFinal, sessionID: "s", laneID: "mic", captureEpoch: 1, providerEpoch: 1,
                             eventID: "e", segmentID: "one", revision: 1, text: "用飞鼠开会。", isFinal: true)
        e.vocabularyCandidates = generator.candidates(in: e.text!)
        var reducer = CaptionReducer(sessionID: "s")
        _ = reducer.apply(e)
        let original = try #require(reducer.snapshot.segments.first)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(CaptionSegment.self, from: data) == original)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "vocabularyCandidates")
        let decoded = try JSONDecoder().decode(CaptionSegment.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.vocabularyCandidates == nil && decoded.sourceText == original.sourceText)
    }

    @Test func finalRecognitionRemainsReviewableWhenTranslationFails() throws {
        var event = CaptionEvent(type: .sourceFinal, sessionID: "s", laneID: "mic", captureEpoch: 1, providerEpoch: 1,
                                 eventID: "e", segmentID: "one", revision: 1, text: "用飞鼠开会。", isFinal: true)
        event.vocabularyCandidates = generator.candidates(in: event.text!)
        var reducer = CaptionReducer(sessionID: "s")
        _ = reducer.apply(event)
        _ = reducer.freezeOpenSegments(reason: "翻译失败")
        let before = try #require(reducer.snapshot.segments.first)
        let candidate = try #require(before.vocabularyCandidates?.first)
        let accepted = reducer.reviewVocabularyCandidate(segmentID: before.id, revision: 1, candidate: candidate, confirm: true)
        #expect(accepted)
        let after = try #require(reducer.snapshot.segments.first)
        #expect(after.sourceText == "用飞书开会。" && after.originalRecognitionText == "用飞鼠开会。")
        #expect(after.presentationState == .frozen && after.incompleteReason == "翻译失败")
    }

    @Test func correctingCoveredSentenceInvalidatesTheOwnerAndLateGroupTranslation() throws {
        var reducer = CaptionReducer(sessionID: "s")
        for (id, text) in [("one", "Let's meet."), ("two", "用飞鼠开会。") ] {
            var event = CaptionEvent(type: .sourceFinal, sessionID: "s", laneID: "mic", captureEpoch: 1, providerEpoch: 1,
                                     eventID: id, segmentID: id, revision: 1, text: text, isFinal: true)
            event.vocabularyCandidates = generator.candidates(in: text)
            _ = reducer.apply(event)
        }
        var translation = CaptionEvent(type: .translationFinal, sessionID: "s", laneID: "mic", captureEpoch: 1, providerEpoch: 1,
            eventID: "t1", text: "Original group translation", isFinal: true, translationID: "group",
            sourceRefs: [SourceRef(segmentID: "one", revision: 1), SourceRef(segmentID: "two", revision: 1)])
        _ = reducer.apply(translation)
        let second = try #require(reducer.snapshot.segments.last)
        #expect(second.translation == nil && second.mergedIntoTranslation == "group")
        let candidate = try #require(second.vocabularyCandidates?.first)
        let accepted = reducer.reviewVocabularyCandidate(segmentID: second.id, revision: 1, candidate: candidate, confirm: true)
        #expect(accepted && reducer.snapshot.segments.first?.translation?.isStale == true)
        translation.eventID = "late"
        translation.text = "Late original group translation"
        _ = reducer.apply(translation)
        #expect(reducer.snapshot.segments.first?.translation?.isStale == true)
        translation.eventID = "updated"
        translation.sourceRefs = [SourceRef(segmentID: "one", revision: 1), SourceRef(segmentID: "two", revision: 2)]
        _ = reducer.apply(translation)
        #expect(reducer.snapshot.segments.first?.translation?.isStale == false)
        translation.eventID = "late-after-update"
        translation.text = "Must not replace newer group translation"
        translation.sourceRefs = [SourceRef(segmentID: "one", revision: 1), SourceRef(segmentID: "two", revision: 1)]
        _ = reducer.apply(translation)
        #expect(reducer.snapshot.segments.first?.translation?.isStale == false)
        #expect(reducer.snapshot.segments.first?.translation?.text == "Late original group translation")
    }
}
