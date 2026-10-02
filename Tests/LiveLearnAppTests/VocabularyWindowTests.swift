import Foundation
import AppKit
import Testing
import SessionStorage
import CloudEngine
@testable import LiveLearnApp

@MainActor
struct VocabularyWindowTests {
    @Test func windowPreferencesAndReopeningKeepExistingWords() {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["LiveLearn", "WhisperKit"], forKey: "hotWords")
        defaults.set(["latency=延迟"], forKey: "glossaryLines")
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.vocabularyWindowPinned)
        settings.vocabularyWindowPinned = true
        #expect(AppSettings(defaults: defaults).vocabularyWindowPinned, "Only an explicit pin is remembered")
        settings.vocabularyWindowPinned = false
        let model = AppModel(settings: settings, preview: .empty())
        model.requestVocabularyWindow()
        model.requestVocabularyWindow()
        #expect(model.openVocabularyWindowRequest == 2)
        #expect(model.openSettingsRequest == 0)
        model.requestSettings(.vocabulary)
        #expect(model.openVocabularyWindowRequest == 3 && model.openSettingsRequest == 0)
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.vocabularyWindowPinned)
        #expect(reopened.hotWords == ["LiveLearn", "WhisperKit"])
        #expect(reopened.glossaryLines == ["latency=延迟"])
    }

    @Test func changesFromIndependentWindowRefreshNextSessionBlueprint() async throws {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        #expect(model.blueprint.deepgram.keyterms.isEmpty)
        settings.hotWords = ["WhisperKit"]
        settings.glossaryLines = ["latency=延迟"]
        let deadline = Date().addingTimeInterval(3)
        while (model.blueprint.deepgram.keyterms != ["WhisperKit", "latency"] || model.blueprint.chat.glossary.isEmpty) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.blueprint.deepgram.keyterms == ["WhisperKit", "latency"])
        #expect(model.blueprint.chat.glossary == [GlossaryEntry(source: "latency", target: "延迟")])
        #expect(model.sessionState == .idle)
    }

    /// The page draws no icon list any more (round 12), but every glyph it still names — the
    /// rail header's +, the "···" menu, the list's actions, the import glyph, the camera — must
    /// resolve, or it silently draws nothing.
    @Test func vocabularyGlyphsExist() {
        for symbol in ["plus", "ellipsis", "pencil", "trash", "xmark", "info.circle", "tray.and.arrow.down", "chevron.right",
                       "chevron.left", "pause", "play", "arrow.counterclockwise", "arrow.clockwise", "minus", "dot.viewfinder"] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }
}
