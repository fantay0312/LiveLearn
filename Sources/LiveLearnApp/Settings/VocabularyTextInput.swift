import AppKit
import SwiftUI

/// Text and placeholder use the same NSTextContainer metrics, including the insertion point.
/// `onFocusChange` reports when the text view takes or gives up first responder, so the field
/// around it can draw its focus edge in the app's own ink.
struct VocabularyTextInput: NSViewRepresentable {
    @Binding var text: String
    let color: NSColor
    let placeholderColor: NSColor
    var requestFocus = false
    var onFocusChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = VocabularyTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 48))
        editor.configure()
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? VocabularyTextView else { return }
        context.coordinator.text = $text
        if editor.string != text && !editor.hasMarkedText() { editor.string = text }
        editor.textColor = color
        editor.insertionPointColor = color
        editor.placeholderColor = placeholderColor
        editor.focusChanged = onFocusChange
        editor.needsDisplay = true
        if requestFocus && !context.coordinator.didFocus {
            context.coordinator.didFocus = true
            Task { @MainActor [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var didFocus = false
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            editor.needsDisplay = true
        }
    }
}

@MainActor
final class VocabularyTextView: NSTextView {
    var placeholder = "添加新词，或粘贴多行词汇"
    var placeholderColor = NSColor.placeholderTextColor
    var focusChanged: ((Bool) -> Void)?

    func configure() {
        font = .systemFont(ofSize: 15)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 48)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(width: 12, height: 14)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        setAccessibilityLabel("添加新词或粘贴多行词汇")
    }

    // Reported after AppKit has settled the responder change, never inside a SwiftUI update.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { report(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { report(false) }
        return resigned
    }

    private func report(_ focused: Bool) {
        guard let focusChanged else { return }
        Task { @MainActor in focusChanged(focused) }
    }

    /// A matching text layout also gives the placeholder the native font baseline.
    func placeholderLayout() -> NSLayoutManager {
        let storage = NSTextStorage(string: placeholder, attributes: [
            .font: font ?? .systemFont(ofSize: 15), .foregroundColor: placeholderColor
        ])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: textContainer?.containerSize ?? NSSize(width: bounds.width - 24, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        // The layout manager keeps its text storage only weakly; force layout before returning
        // and keep the storage for the duration of drawing through this view's retained value.
        placeholderStorage = storage
        manager.ensureLayout(for: container)
        return manager
    }

    private var placeholderStorage: NSTextStorage?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let manager = placeholderLayout()
        manager.drawGlyphs(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: textContainerOrigin)
    }
}
