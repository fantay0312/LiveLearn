import Testing
@testable import EngineKit

@Suite("Conservative vocabulary matching")
struct VocabularyMatcherTests {
    @Test func restoresSpellingWithoutFuzzySubstitution() {
        let matcher = VocabularyMatcher([VocabularyTerm(source: "WhisperKit", target: "WhisperKit"),
                                         VocabularyTerm(source: "SwiftUI", target: "SwiftUI")])
        #expect(matcher.replacing(in: "whisper kit, SWIFT-UI and swiftui") == "WhisperKit, SwiftUI and SwiftUI")
        #expect(matcher.replacing(in: "whispered kit; SwiftUIBuilder; xwhisperkit") == "whispered kit; SwiftUIBuilder; xwhisperkit")
        #expect(matcher.replacing(in: "whisper\nkit") == "whisper\nkit")
    }

    @Test func protectsShortWordsAndAmbiguousNames() {
        let matcher = VocabularyMatcher([VocabularyTerm(source: "US", target: "美国"),
                                         VocabularyTerm(source: "iOS", target: "iOS"),
                                         VocabularyTerm(source: "ABCD", target: "first"),
                                         VocabularyTerm(source: "abcd", target: "second")])
        #expect(matcher.replacing(in: "help us use US and u s") == "help us use 美国 and 美国")
        #expect(matcher.replacing(in: "ios iOS i o s") == "ios iOS iOS")
        #expect(matcher.replacing(in: "ABCD abcd AbCd") == "first second AbCd")
    }

    @Test func takesLongestTermPreservingPunctuationAndSpacing() {
        let matcher = VocabularyMatcher([VocabularyTerm(source: "machine", target: "机器"),
                                         VocabularyTerm(source: "machine learning", target: "机器学习"),
                                         VocabularyTerm(source: "延迟", target: "latency")])
        #expect(matcher.replacing(in: "machine learning, machine.  ") == "机器学习, 机器.  ")
        #expect(matcher.replacing(in: "降低延迟。") == "降低latency。")
        #expect(matcher.replacing(in: "machinelearningBudget") == "machinelearningBudget")
        #expect(matcher.replacing(in: "") == "")
    }

    @Test func emptyAndDuplicateWordsDoNotChangeOutput() {
        #expect(VocabularyMatcher.uniqueWords(["SwiftUI", " SwiftUI ", "", "\n "]) == ["SwiftUI"])
        #expect(VocabularyMatcher([]).replacing(in: "untouched") == "untouched")
    }
}
