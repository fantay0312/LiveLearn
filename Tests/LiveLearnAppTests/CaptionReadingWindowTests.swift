import Foundation
import Testing
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct CaptionReadingWindowTests {
    @Test func continuousUnpunctuatedChineseStillHasThreeReadingCues() throws {
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
        let incoming = try #require(reading.incoming)
        #expect(previous.translation != current.translation && current.translation != incoming.translation)
        #expect([previous, current, incoming].allSatisfy { ($0.translation?.count ?? 0) <= 22 })
        #expect(incoming.translation?.hasSuffix("我们继续往下听") == true)
        #expect(segment.sourceText == text && segment.translation?.text == text)
    }

    @Test func sourceOnlyAndMismatchedTranslationStayBoundedWithoutInventingPairs() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = String(repeating: "未插入标点的识别内容", count: 8)
        segment.translation = nil
        segment.presentationState = .preview
        let sourceOnly = CaptionReadingWindow(current: segment, previous: nil, capacity: 22)
        #expect(sourceOnly.previous != nil && sourceOnly.current != nil && sourceOnly.incoming != nil)
        #expect(sourceOnly.incoming?.source.count ?? 0 <= 22)
        #expect(sourceOnly.incoming?.primaryText(showSource: false) == nil)

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

    @Test func unmatchedOrStaleTranslationIsNotSplitIntoInventedPairs() throws {
        var segment = try #require(SampleData.runningSnapshot().captions.segments.first)
        segment.sourceText = "First sentence. Second sentence."
        segment.translation?.text = "两句话合译成一句。"
        var window = CaptionReadingWindow(current: segment, previous: nil)
        #expect(window.current?.source == segment.sourceText && window.previous == nil)
        segment.translation?.text = "第一句。第二句。"
        segment.translation?.isStale = true
        window = CaptionReadingWindow(current: segment, previous: nil)
        #expect(window.previous?.source == "" && window.current?.isStale == true)
        #expect(window.current?.source == segment.sourceText)
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
