import Foundation
import Testing
@testable import CloudEngine

struct VocabularyLibraryTests {
    @Test func separatorsAndFirstDelimiter() {
        let parsed = GlossaryEntry.parse(["a=>甲", "b->乙", "c\t丙", "d＝丁", "e→戊", "f=one=>two"])
        #expect(parsed.map(\.target) == ["甲", "乙", "丙", "丁", "戊", "one=>two"])
    }

    @Test func mixedImportIsPreviewAndReportsProblems() {
        let library = VocabularyLibrary(hotWords: ["SwiftUI"], glossaryLines: ["latency=延迟"])
        let report = library.previewImport("SwiftUI\n Kubernetes \nlatency=>延迟\nlatency=等待\nbroken=\n=译文\nmissing\t\ncloud\t云端")
        #expect(report.added.map(\.raw) == ["Kubernetes", "cloud=云端"])
        #expect(report.duplicates == 2)
        #expect(report.issues.count == 4)
        #expect(report.issues.first?.contains("已有译法") == true)
        #expect(library.hotWords == ["SwiftUI"])
        #expect(report.library.glossaryLines == ["latency=延迟", "cloud=云端"])
    }

    @Test func duplicateHandlingPreservesMeaningfulCaseAndUnicode() throws {
        var library = VocabularyLibrary(hotWords: ["café", "US"])
        #expect(throws: VocabularyError.self) { try library.save(kind: .hotWord, source: " cafe\u{301} ") }
        try library.save(kind: .hotWord, source: "us")
        #expect(library.hotWords == ["café", "US", "us"])
        let report = library.previewImport("new\nnew\nnew")
        #expect(report.added.count == 1)
        #expect(report.duplicates == 2)
    }

    @Test func failedEditIsAtomicAndSuccessfulEditKeepsOrder() throws {
        var library = VocabularyLibrary(hotWords: ["one", "two"], glossaryLines: ["a=甲", "b=乙"])
        let before = library
        let first = library.items[0]
        #expect(throws: VocabularyError.self) { try library.save(kind: .hotWord, source: "two", replacing: first) }
        #expect(library == before)
        let glossary = library.items[2]
        #expect(throws: VocabularyError.self) { try library.save(kind: .glossary, source: "a", target: "", replacing: glossary) }
        #expect(library == before)
        try library.save(kind: .glossary, source: "a", target: "新译法", replacing: glossary)
        #expect(library.glossaryLines == ["a=新译法", "b=乙"])
    }

    @Test func glossaryLimitIsExplicitAndStillAllowsEditing() throws {
        var library = VocabularyLibrary(glossaryLines: (0..<200).map { "term\($0)=译文\($0)" })
        let first = library.items[0]
        let report = library.previewImport("extra=额外\nSwiftUI")
        #expect(report.issues.count == 1)
        #expect(report.added.map(\.raw) == ["SwiftUI"])
        #expect(report.library.glossaryLines.count == 200)
        try library.save(kind: .glossary, source: "term0", target: "新译文", replacing: first)
        #expect(library.glossaryLines.first == "term0=新译文")
    }

    @Test func backupRoundTripPreservesTypedHotWordsAndTargets() throws {
        let library = VocabularyLibrary(hotWords: ["C++", "a=b", "https://example.test"], glossaryLines: ["formula=a=b", "模型=模型：一"])
        let text = String(decoding: try library.exportData(), as: UTF8.self)
        let restored = VocabularyLibrary().previewImport(text)
        #expect(restored.issues.isEmpty)
        #expect(restored.library == library)
        #expect(library.previewImport(text).duplicates == 5)
    }

    @Test func corruptAndOversizedImportsDoNotCreateJunkWords() {
        let library = VocabularyLibrary()
        let corrupt = library.previewImport("{\"hotWords\":[\"hello\"]}")
        #expect(corrupt.added.isEmpty && corrupt.issues.count == 1)
        let oversized = library.previewImport(String(repeating: "a", count: VocabularyLibrary.importByteLimit + 1))
        #expect(oversized.added.isEmpty && oversized.issues.count == 1)
        let tooMany = library.previewImport((0..<2001).map { "word\($0)" }.joined(separator: "\n"))
        #expect(tooMany.added.isEmpty && tooMany.issues.count == 1)
    }

    @Test func searchMatchesSourceTranslationAndMultipleTokens() {
        let item = VocabularyItem(kind: .glossary, raw: "Machine Learning=机器学习")
        #expect(item.matches("machine 学习"))
        #expect(item.matches("LEARNING"))
        #expect(!item.matches("machine 回滚"))
        #expect(item.matches(" "))
    }

    @Test func legacyInvalidEntriesStayVisibleAndCanBeRepaired() throws {
        var library = VocabularyLibrary(glossaryLines: ["missing separator", "a=甲"])
        let invalid = library.items[0]
        #expect(!invalid.isValid)
        try library.save(kind: .glossary, source: "fixed", target: "修复", replacing: invalid)
        #expect(library.glossaryLines == ["fixed=修复", "a=甲"])
    }

    @Test func rejectsMultilineAndAmbiguousGlossarySource() {
        var library = VocabularyLibrary()
        #expect(throws: VocabularyError.self) { try library.save(kind: .hotWord, source: "a\nb") }
        #expect(throws: VocabularyError.self) { try library.save(kind: .glossary, source: "a=b", target: "甲") }
        #expect(throws: VocabularyError.self) { try library.save(kind: .hotWord, source: String(repeating: "a", count: 241)) }
        #expect(library.items.isEmpty)
    }

    @Test func windowsNewlinesAndBOMImport() {
        let report = VocabularyLibrary().previewImport("\u{FEFF}WhisperKit\r\n latency＝延迟 \r\n\r\n")
        #expect(report.added.map(\.raw) == ["WhisperKit", "latency=延迟"])
        #expect(report.issues.isEmpty)
    }
}
