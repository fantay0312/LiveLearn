import Foundation
import Testing
@testable import LiveLearnApp

struct DictationInputSnapshotTests {
    @Test func editorWithoutSelectionCanPasteButCannotReplaceTheDocument() {
        let before = DictationInputSnapshot(text: "现有文字", selection: nil, selectedText: nil)
        #expect(before.insertion == nil)
        #expect(before.accepts(before))
        #expect(!before.accepts(.init(text: "用户新增文字", selection: nil, selectedText: nil)))
        #expect(!before.accepts(.init(text: nil, selection: nil, selectedText: nil)))
    }

    @Test func readableSelectionStillProtectsTheCursorWithoutFullText() {
        let before = DictationInputSnapshot(text: nil, selection: NSRange(location: 8, length: 2), selectedText: "内容")
        #expect(before.insertion == nil)
        #expect(before.accepts(before))
        #expect(!before.accepts(.init(text: nil, selection: NSRange(location: 10, length: 0), selectedText: "")))
    }

    @Test func completeEditorTracksOnlyOwnedUTF16Range() throws {
        let before = DictationInputSnapshot(text: "之前🦋之后", selection: NSRange(location: 2, length: 2), selectedText: "🦋")
        var insertion = try #require(before.insertion)
        insertion.replace(with: "SwiftUI")
        #expect(insertion.expectedText == "之前SwiftUI之后")
        #expect(insertion.replacementRange == NSRange(location: 2, length: 7))
    }
}
