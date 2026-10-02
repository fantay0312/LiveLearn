import Testing
import Foundation
import Translation
import EngineKit
@testable import LocalEngine

@Suite("Apple translator normalisation")
struct LocalTranslatorTests {
    @Test func protectedTermsRemainExactAcrossChineseNormalization() {
        guard #available(macOS 26.4, *) else { return }
        let matcher = VocabularyMatcher([VocabularyTerm(source: "latency", target: "時延"), VocabularyTerm(source: "machine learning", target: "ML")])
        let text = "Lower latency with machine learning."
        let input = AppleTextTranslator.protectedInput(text, matches: matcher.matches(in: text))
        #expect(String(input.characters) == "Lower 時延 with ML.")
        let protected = input.runs.filter { $0.translation.skipsTranslation == true }.map { String(input[$0.range].characters) }
        #expect(protected == ["時延", "ML"])
        #expect(AppleTextTranslator.normalise("我們降低時延並訓練模型。", simplifyChinese: true, preserving: ["時延"]) == "我们降低時延并训练模型。")
    }

    @Test func legacyTranslationPreservesFixedTermsAndWhitespace() async throws {
        guard #available(macOS 26, *) else { return }
        let matcher = VocabularyMatcher([VocabularyTerm(source: "latency", target: "时延")])
        let text = "lower latency, then test."
        let result = try await AppleTextTranslator.translateSpans(text, matches: matcher.matches(in: text)) { $0.uppercased() }
        #expect(result == "LOWER 时延, THEN TEST.")
        let onlyTerm = "latency"
        let exact = try await AppleTextTranslator.translateSpans(onlyTerm, matches: matcher.matches(in: onlyTerm)) { _ in Issue.record("A fixed term must never be sent for translation"); return "wrong" }
        #expect(exact == "时延")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_TEST_APPLE_GLOSSARY"] == "1"))
    func installedAppleModelHonorsFixedTranslations() async throws {
        guard #available(macOS 26.4, *) else { return }
        let translator = AppleTextTranslator(glossary: [VocabularyTerm(source: "latency", target: "時延"), VocabularyTerm(source: "machine learning", target: "機器學習")])
        try #require(await translator.availability(source: "en", target: "zh-Hans").isReady)
        try await translator.prepare(source: "en", target: "zh-Hans")
        defer { translator.cancel() }
        let whole = try await translator.translate("latency", source: "en", target: "zh-Hans", isFinal: true)
        #expect(whole == "時延")
        let sentence = try await translator.translate("We reduce latency with machine learning.", source: "en", target: "zh-Hans", isFinal: true)
        print("Apple protected glossary output: \(sentence)")
        #expect(sentence.contains("時延") && sentence.contains("機器學習"))
        #expect(!sentence.contains("latency") && !sentence.contains("machine learning"))
    }

    @Test("Traditional output is folded to Simplified only for a zh-Hans target")
    func simplifiesOnlyForSimplifiedTarget() {
        guard #available(macOS 26, *) else { return }
        let traditional = "然後，我們將看看機器學習如何訓練。"
        #expect(AppleTextTranslator.normalise(traditional, simplifyChinese: true) == "然后，我们将看看机器学习如何训练。")
        #expect(AppleTextTranslator.normalise(traditional, simplifyChinese: false) == traditional)
        // Already-simplified text and non-Chinese text pass through unchanged.
        #expect(AppleTextTranslator.normalise("最重要的想法是模型从例子中学习。", simplifyChinese: true) == "最重要的想法是模型从例子中学习。")
        #expect(AppleTextTranslator.normalise("Finally, there will be time.", simplifyChinese: true) == "Finally, there will be time.")
    }
}
