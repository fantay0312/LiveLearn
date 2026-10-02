import Foundation
import Testing
import WhisperKit
@testable import WhisperEngine

struct WhisperVocabularyRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_TEST_WHISPER_VOCAB_AUDIO"] != nil))
    func installedModelAcceptsVocabularyWithAndWithoutLanguage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LIVELEARN_TEST_WHISPER_VOCAB_AUDIO"])
        try #require(WhisperModelStore.isInstalled("openai_whisper-base"))
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        let decoder = WhisperKitDecoder(variant: "openai_whisper-base")
        try await decoder.load()
        for language: String? in ["en", nil] {
            let result = try await decoder.decode(samples, language: language, partial: false, vocabulary: ["WhisperKit", "latency", "machine learning"])
            let output = result.segments.map(\.text).joined(separator: " ")
            print("Whisper vocabulary runtime (\(language ?? "auto")): \(output)")
            #expect(!result.interrupted && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(result.language == "en")
        }
        await decoder.unload()
    }
}
