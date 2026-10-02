import Testing
@testable import LiveLearnApp

@MainActor
struct TranslationReadinessTests {
    @Test func automaticInputStillOffersLanguagePackDownloads() {
        let pairs = LocalModelSettings.translationDirections(for: [
            LanguageDirection(source: "auto", target: "zh-Hans"),
            LanguageDirection(source: "en", target: "zh-Hans")
        ])
        #expect(pairs.contains(LanguageDirection(source: "en", target: "zh-Hans")))
        #expect(pairs.contains(LanguageDirection(source: "ja", target: "zh-Hans")))
        #expect(!pairs.contains { $0.source == "auto" || $0.source == $0.target })
        #expect(Set(pairs.map(\.key)).count == pairs.count)
    }

    @Test func explicitDirectionsStayFocusedAndDeduplicateAliases() {
        let pairs = LocalModelSettings.translationDirections(for: [
            LanguageDirection(source: "en_US", target: "zh"),
            LanguageDirection(source: "en", target: "zh-Hans"),
            LanguageDirection(source: "ja", target: "en")
        ])
        #expect(pairs == [LanguageDirection(source: "en", target: "zh-Hans"), LanguageDirection(source: "ja", target: "en")])
    }
}
