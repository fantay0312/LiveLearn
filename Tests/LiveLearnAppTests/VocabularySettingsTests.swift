import Foundation
import Testing
import CloudEngine
import EngineKit
@testable import LiveLearnApp

@MainActor
struct VocabularySettingsTests {
    @Test func retiredModeDoesNotEraseStageConfigurationOrWords() {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("demo", forKey: "engine")
        defaults.set("deepgram", forKey: "recognizer")
        defaults.set("chat", forKey: "translator")
        defaults.set(["WhisperKit"], forKey: "hotWords")
        defaults.set(["latency=延迟"], forKey: "glossaryLines")
        let settings = AppSettings(defaults: defaults)
        #expect(defaults.object(forKey: "engine") == nil)
        #expect(settings.recognizer == .deepgram && settings.translator == .chat)
        #expect(settings.hotWords == ["WhisperKit"] && settings.glossaryLines == ["latency=延迟"])
        #expect(EngineBlueprint.providerID == "pipeline")
    }

    @Test func importedVocabularyPersistsAndReachesConfiguredStages() {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let imported = VocabularyLibrary().previewImport("WhisperKit\nlatency=>延迟").library
        settings.hotWords = imported.hotWords
        settings.glossaryLines = imported.glossaryLines
        let restored = AppSettings(defaults: defaults)
        let bp = EngineBlueprint(settings: restored, credentials: .empty)
        #expect(bp.recognitionVocabulary == ["WhisperKit", "latency"])
        #expect(bp.deepgram.keyterms == bp.recognitionVocabulary)
        #expect(bp.doubao.hotWords == bp.recognitionVocabulary)
        #expect(bp.soniox.terms == bp.recognitionVocabulary)
        #expect(bp.geminiLive.vocabulary == bp.recognitionVocabulary)
        #expect(bp.realtime.prompt?.contains("WhisperKit") == true)
        #expect(bp.chat.glossary == [GlossaryEntry(source: "latency", target: "延迟")])
        #expect(bp.translationVocabulary == [VocabularyTerm(source: "latency", target: "延迟")])
        #expect(bp.anthropic.glossary == bp.chat.glossary && bp.gemini.glossary == bp.chat.glossary)
    }

    @Test func everyEngineUsesVocabularyWithHonestNativeSupport() throws {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for recognizer in RecognizerChoice.allCases {
            settings.recognizer = recognizer
            let blueprint = EngineBlueprint(settings: settings, credentials: .empty)
            #expect(blueprint.vocabularyTakers.hotWords)
            #expect(blueprint.usesNativeRecognitionVocabulary == ![.appleSpeech, .paraformer].contains(recognizer))
        }
        for translator in TranslatorChoice.allCases {
            settings.translator = translator
            let blueprint = EngineBlueprint(settings: settings, credentials: .empty)
            #expect(blueprint.vocabularyTakers.glossary)
            #expect(try blueprint.makeTranslator().supportsGlossary)
            #expect(try blueprint.makeProvider().capabilities.supportsGlossary == .supported)
        }
    }

    @Test func starterPacksAreValidAndIdempotent() {
        for pack in VocabularyStarterPack.all {
            let first = VocabularyLibrary().previewImport(pack.text)
            #expect(first.issues.isEmpty)
            #expect(first.added.count == pack.count)
            let second = first.library.previewImport(pack.text)
            #expect(second.added.isEmpty && second.duplicates == pack.count)
        }
    }

    @Test func backupWritesDistinctFilesAndRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn.testing.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = VocabularyLibrary(hotWords: ["SwiftUI"], glossaryLines: ["latency=延迟"])
        let first = try VocabularyBackupStore.save(library, directory: folder)
        let second = try VocabularyBackupStore.save(library, directory: folder)
        #expect(first != second)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
        let restored = VocabularyLibrary().previewImport(try String(contentsOf: first, encoding: .utf8))
        #expect(restored.library == library && restored.issues.isEmpty)
    }
}
