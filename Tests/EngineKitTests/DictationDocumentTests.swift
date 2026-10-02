import Foundation
import Testing
@testable import EngineKit

struct DictationDocumentTests {
    @Test func replacesPartialAndKeepsDistinctSegments() {
        var document = DictationDocument()
        document.receive(.init(startNs: 0, endNs: 100, text: "请用扣德", isFinal: false))
        document.receive(.init(startNs: 0, endNs: 120, text: "请用Codex", isFinal: false))
        #expect(document.text == "请用Codex")
        document.receive(.init(startNs: 0, endNs: 130, text: "请用 Codex。", isFinal: true))
        document.receive(.init(startNs: 130, endNs: 200, text: "Fix SwiftUI", isFinal: false))
        #expect(document.text == "请用 Codex。Fix SwiftUI")
        document.receive(.init(startNs: 0, endNs: 120, text: "迟到的旧结果", isFinal: false))
        #expect(document.text == "请用 Codex。Fix SwiftUI")
        document.receive(.init(startNs: 130, endNs: 210, text: "Fix SwiftUI.", isFinal: true))
        document.receive(.init(startNs: 130, endNs: 210, text: "Fix SwiftUI.", isFinal: true))
        #expect(document.text == "请用 Codex。Fix SwiftUI.")
    }

    @Test func emptyFinalRemovesFalseHypothesis() {
        var document = DictationDocument()
        document.receive(.init(startNs: 0, endNs: 100, text: "幻觉", isFinal: false))
        document.receive(.init(startNs: 0, endNs: 100, text: "", isFinal: true))
        #expect(document.text.isEmpty)
    }

    @Test func preservesMixedLanguageAndEnglishWordBoundaries() {
        #expect(DictationDocument.join("Hello", "world") == "Hello world")
        #expect(DictationDocument.join("你好", "世界") == "你好世界")
        #expect(DictationDocument.join("SwiftUI ", "API") == "SwiftUI API")
        #expect(DictationDocument.join("version 2.0", "works") == "version 2.0 works")
    }

    @Test func ownsUTF16SelectionAndRejectsUserEdits() throws {
        let original = "👩🏽‍💻 前缀 旧字 后缀"
        let range = (original as NSString).range(of: "旧字")
        var edit = try #require(DictationInsertion(text: original, selection: range))
        #expect(edit.accepts(text: original, selection: range))
        edit.replace(with: "SwiftUI 和中文🙂")
        #expect(edit.expectedText == "👩🏽‍💻 前缀 SwiftUI 和中文🙂 后缀")
        #expect(edit.replacementRange.length == "SwiftUI 和中文🙂".utf16.count)
        #expect(!edit.accepts(text: edit.expectedText + "用户补充", selection: edit.expectedSelection))
        #expect(!edit.accepts(text: edit.expectedText, selection: .init(location: 0, length: 0)))
        edit.replace(with: "Codex")
        #expect(edit.expectedText == "👩🏽‍💻 前缀 Codex 后缀")
        #expect(DictationInsertion(text: "🙂", selection: .init(location: 1, length: 0)) == nil)
    }
}
