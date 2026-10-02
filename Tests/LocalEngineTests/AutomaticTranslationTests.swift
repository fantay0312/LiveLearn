import Foundation
import Testing
import ProviderAdapters
@testable import LocalEngine

@Suite("Apple automatic source translation")
struct AutomaticTranslationTests {
    @Test func automaticReadinessRequiresAnInstalledDirection() async {
        let installed = await LocalEngineAvailability.automaticTranslationState(target: "zh-Hans") { source, target in
            #expect(source != target && source != "auto")
            return source == "en" ? .installed : .downloadable
        }
        #expect(installed == .installed)
        let missing = await LocalEngineAvailability.automaticTranslationState(target: "zh-Hans") { source, _ in
            source == "en" ? .downloadable : .unsupported
        }
        #expect(missing == .downloadable)
        let unsupported = await LocalEngineAvailability.automaticTranslationState(target: "invalid") { _, _ in .unsupported }
        #expect(unsupported == .unsupported)
    }

    @Test func identifiesTextOnDevice() throws {
        guard #available(macOS 26, *) else { return }
        #expect(try AppleTextTranslator.detectedSource(in: "This is a test of automatic translation.") == "en")
        #expect(try AppleTextTranslator.detectedSource(in: "这是一句中文，不需要重复翻译。") == "zh-Hans")
        #expect(try AppleTextTranslator.detectedSource(in: "今日は天気がいいですね。") == "ja")
        #expect(throws: ProviderError.self) { try AppleTextTranslator.detectedSource(in: "") }
    }

    @Test func automaticPreparationDefersModelsAndPreservesSameLanguage() async throws {
        guard #available(macOS 26, *) else { return }
        let translator = AppleTextTranslator()
        try await translator.prepare(source: nil, target: "zh-Hans")
        #expect(try await translator.translate("这是一句中文，不需要重复翻译。", source: nil, target: "zh-Hans", isFinal: true) == "这是一句中文，不需要重复翻译。")
        #expect(try await translator.translate("12345!", source: nil, target: "zh-Hans", isFinal: true) == "12345!")
        translator.cancel()
        await #expect(throws: ProviderError.self) {
            try await translator.translate("Hello", source: nil, target: "zh-Hans", isFinal: true)
        }
        try await translator.prepare(source: "auto", target: "zh-Hans")
        #expect(try await translator.translate("这是一句中文。", source: "auto", target: "zh-Hans", isFinal: true) == "这是一句中文。")
        translator.cancel()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_TEST_APPLE_AUTO"] == "1"))
    func realInstalledModelsTranslateAutomaticAndExplicitSources() async throws {
        guard #available(macOS 26, *) else { return }
        let translator = AppleTextTranslator()
        defer { translator.cancel() }
        try #require(await translator.availability(source: nil, target: "zh-Hans").isReady)
        try #require(await translator.availability(source: "en", target: "zh-Hans").isReady)
        try await translator.prepare(source: nil, target: "zh-Hans")
        let text = "The weather is nice today. We can go for a walk in the park."
        let automatic = try await translator.translate(text, source: nil, target: "zh-Hans", isFinal: true)
        print("Apple automatic en → zh-Hans: \(automatic)")
        #expect(automatic.contains("天气") && automatic != text)
        let chinese = "这是一句中文，不需要重复翻译。"
        #expect(try await translator.translate(chinese, source: nil, target: "zh-Hans", isFinal: true) == chinese)
        #expect(try await translator.translate(text, source: nil, target: "zh-Hans", isFinal: true) == automatic)

        try await translator.prepare(source: "en", target: "zh-Hans")
        let explicit = try await translator.translate(text, source: "en", target: "zh-Hans", isFinal: true)
        #expect(explicit == automatic)

        if await LocalEngineAvailability.translationState(source: "ja", target: "zh-Hans") == .downloadable {
            try await translator.prepare(source: nil, target: "zh-Hans")
            do {
                _ = try await translator.translate("今日は天気がいいですね。", source: nil, target: "zh-Hans", isFinal: false)
                Issue.record("An uninstalled preview language must not translate")
            } catch let error as ProviderError {
                #expect(error.classification == .retryable)
            }
            do {
                _ = try await translator.translate("今日は天気がいいですね。", source: nil, target: "zh-Hans", isFinal: true)
                Issue.record("A missing Japanese pack must not be treated as ready")
            } catch let error as ProviderError {
                #expect(error.classification == .userFixable)
                #expect(error.message.contains("日语") && error.message.contains("本地模型"))
                print("Apple missing pack: \(error.message)")
            }
        }
    }
}
