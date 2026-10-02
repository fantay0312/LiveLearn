import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct VocabularyTextInputTests {
    @Test func placeholderAndTypedGlyphShareOriginAndBaseline() throws {
        for width: CGFloat in [240, 468] {
            for word in ["添加新词", "WhisperKit"] {
                let editor = VocabularyTextView(frame: NSRect(x: 0, y: 0, width: width, height: 80))
                editor.configure()
                editor.placeholder = word
                let placeholder = editor.placeholderLayout()
                let expected = placeholder.location(forGlyphAt: 0)
                let expectedLine = placeholder.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                editor.string = word
                let native = try #require(editor.layoutManager)
                let container = try #require(editor.textContainer)
                native.ensureLayout(for: container)
                let actual = native.location(forGlyphAt: 0)
                let actualLine = native.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                #expect(abs(actual.x - expected.x) < 0.01)
                #expect(abs(actual.y - expected.y) < 0.01)
                #expect(actualLine.origin == expectedLine.origin)
                #expect(editor.textContainerOrigin == NSPoint(x: 12, y: 14))
                #expect(container.lineFragmentPadding == 0)
            }
        }
    }
}
