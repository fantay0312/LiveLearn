import Foundation
import Testing
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct CaptionReadingWindowTests {
    @Test func continuousUnpunctuatedChineseKeepsItsNewestWordsOnTheProminentLine() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        let text = "有我的模样让我睡风又有的让我变成一笔眼马起远发请你忘掉我的模样然后还有下一句话接着讲述今天发生的故事我们继续往下听"
        segment.sourceText = text
        segment.translation?.text = text
        segment.sourceFinal = false
        segment.presentationState = .preview
        segment.translation?.isFinal = false
        let reading = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        let previous = try #require(reading.previous)
        let current = try #require(reading.current)
        #expect(previous.translation != current.translation && reading.incoming == nil)
        #expect([previous, current].allSatisfy { ($0.translation?.count ?? 0) <= 22 })
        #expect(current.translation?.hasSuffix("我们继续往下听") == true)
        #expect(segment.sourceText == text && segment.translation?.text == text)
    }

    @Test func theSentenceBeingSpokenTakesTheProminentLineOnceItHasATranslation() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        var live = try #require(segments.last)
        let settled = try #require(segments.dropLast().last)
        #expect(live.presentationState == .preview && live.translation == nil)
        // Nothing translated yet: the settled line stays, the new words wait under it.
        var window = CaptionReadingWindow(current: live, previous: settled)
        #expect(window.current?.translation == settled.translation?.text)
        #expect(window.incoming?.source == live.sourceText)
        // The first partial translation, already a revision behind its source.
        var partial = try #require(settled.translation)
        partial.text = "在我们分成两组之前"
        partial.isFinal = false
        partial.isStale = true
        live.translation = partial
        window = CaptionReadingWindow(current: live, previous: settled)
        #expect(window.current?.translation == "在我们分成两组之前")
        #expect(window.current?.source == live.sourceText)
        #expect(window.previous?.translation == settled.translation?.text)
        #expect(window.incoming == nil)
    }

    @Test func aFewOpeningWordsDoNotFlashUnderTheSettledLine() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        var opening = try #require(segments.last)
        let settled = try #require(segments.dropLast().last)
        opening.sourceText = "Any que"
        let window = CaptionReadingWindow(current: opening, previous: settled)
        #expect(window.current?.translation == settled.translation?.text && window.incoming == nil)
    }

    @Test func aLineThatHasOnlyJustWrappedWaitsAndAFinishedSentenceNeverEndsOnAStub() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        let full = "这一行已经写满二十二个字的宽度所以马上要换行"
        #expect(full.count == 22)
        segment.sourceText = "One sentence that is still being spoken"
        segment.translation?.text = full + "了"
        segment.translation?.isFinal = false
        segment.sourceFinal = false
        segment.presentationState = .preview
        // Open: one more glyph than the line holds does not replace the line the reader is on.
        var window = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        #expect(window.current?.translation == full && window.previous == nil)
        #expect(window.current?.source == segment.sourceText)
        // Enough new words: the new line takes over and the full one moves up.
        segment.translation?.text = full + "了然后继续往下说"
        window = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        #expect(window.current?.translation == "了然后继续往下说" && window.previous?.translation == full)
        // Finished with a one-glyph tail: two even lines instead of a stub.
        segment.translation?.text = full + "了"
        segment.translation?.isFinal = true
        segment.sourceFinal = true
        segment.presentationState = .final
        window = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        let first = try #require(window.previous?.translation), second = try #require(window.current?.translation)
        #expect(first + second == full + "了" && abs(first.count - second.count) <= 1)
        let english = CaptionReadingWindow.readingUnits("The quick brown fox jumps over the lazy dog and runs on home.", capacity: 30)
        #expect(english == ["The quick brown fox jumps over", "the lazy dog and runs on home."])
    }

    @Test func sourceOnlyAndMismatchedTranslationStayBoundedWithoutInventingPairs() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = String(repeating: "未插入标点的识别内容", count: 8)
        segment.translation = nil
        segment.presentationState = .preview
        let sourceOnly = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        #expect(sourceOnly.previous != nil && sourceOnly.current != nil && sourceOnly.incoming == nil)
        #expect(sourceOnly.current?.source.count ?? 0 <= 22)
        #expect(sourceOnly.current?.primaryText(showSource: false) == nil)

        var bilingual = try #require(SampleData.runningSnapshot().captions.segments.first)
        bilingual.sourceText = "One complete English sentence."
        bilingual.translation?.text = String(repeating: "没有标点的连续中文译文", count: 6)
        let translated = CaptionReadingWindow(current: bilingual, previous: nil, capacity: 22)
        #expect(translated.previous?.translation?.count ?? 0 <= 22)
        #expect(translated.previous?.source == "")
        #expect(translated.current?.source == bilingual.sourceText)
    }

    @Test func hidingSourceAlsoHidesUntranslatedCurrentAndIncomingText() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        let pending = try #require(segments.last)
        let first = CaptionReadingWindow(current: pending, previous: nil)
        #expect(first.current?.primaryText(showSource: false) == nil)
        #expect(first.current?.primaryText(showSource: true) == pending.sourceText)
        let active = CaptionReadingWindow(current: pending, previous: segments.dropLast().last)
        #expect(active.incoming?.primaryText(showSource: false) == nil)
        #expect(active.current?.primaryText(showSource: false) == segments.dropLast().last?.translation?.text)
    }

    @Test func longBilingualSegmentsBecomeRecentSentencesWithoutEditingTranscript() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = "First sentence. Second sentence. Third sentence."
        segment.translation?.text = "第一句话。第二句话。第三句话。"
        let original = segment
        let window = CaptionReadingWindow(current: segment, previous: nil)
        #expect(window.current?.translation == "第三句话。")
        #expect(window.current?.source == "Third sentence.")
        #expect(window.previous?.translation == "第二句话。")
        #expect(segment == original)
    }

    @Test func incomingWordsDoNotReplaceTheSettledSentence() throws {
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        let pending = try #require(segments.last)
        let settled = try #require(segments.dropLast().last)
        let window = CaptionReadingWindow(current: pending, previous: settled, earlier: segments.dropLast(2).last)
        #expect(window.current?.translation == settled.translation?.text)
        #expect(window.incoming?.source == pending.sourceText)
        #expect(window.previous != nil)
    }

    @Test func unmatchedTranslationIsNotSplitIntoInventedPairsAndAStaleOnePairsTheSameWay() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = "First sentence. Second sentence."
        segment.translation?.text = "两句话合译成一句。"
        var window = CaptionReadingWindow(current: segment, previous: nil)
        #expect(window.current?.source == segment.sourceText && window.previous == nil)
        // A live sentence is stale between every two partial translations; its source row
        // must read the same in both states.
        segment.translation?.text = "第一句。第二句。"
        let fresh = CaptionReadingWindow(current: segment, previous: nil)
        segment.translation?.isStale = true
        window = CaptionReadingWindow(current: segment, previous: nil)
        #expect(window == fresh)
        #expect(window.previous?.source == "First sentence." && window.current?.source == "Second sentence.")
    }

    @Test func unpunctuatedTextKeepsTheLatestGraphemesAndWords() {
        let chinese = String(repeating: "很长的中文内容", count: 50) + "最新的内容"
        let excerpt = CaptionReadingWindow.excerpt(chinese, capacity: 48)
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("最新的内容"))
        #expect(excerpt.count <= 48)
        let english = String(repeating: "Previous words in a long transcript ", count: 20) + "the latest words"
        #expect(CaptionReadingWindow.excerpt(english, capacity: 24).hasSuffix("the latest words"))
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 80)
        #expect(CaptionReadingWindow.excerpt(emoji, capacity: 12) == "…" + String(repeating: "👨‍👩‍👧‍👦", count: 11))
    }

    @Test func mergedTranslationOwnerSurvivesInTheOverlayTail() throws {
        var snapshot = SampleData.runningSnapshot(includeGap: false)
        var segments = Array(snapshot.captions.segments.prefix(3))
        let coveredIDs = segments.map(\.id)
        segments[0].translation?.coveredSegmentIDs = coveredIDs
        let translationID = try #require(segments[0].translation?.id)
        for index in 1..<segments.count {
            segments[index].translation = nil
            segments[index].mergedIntoTranslation = translationID
        }
        snapshot.captions.items = segments.map(CaptionItem.segment)
        let suite = "LiveLearn.testing.reading-window.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: snapshot)
        #expect(model.laneTails["remote"]?.current?.translation?.id == translationID)
        #expect(model.laneTails["remote"]?.current?.sourceText == segments.map(\.sourceText).joined(separator: " "))
        #expect(model.transcriptRows.count == 3)
        #expect(model.snapshot.captions == snapshot.captions)
    }
}
