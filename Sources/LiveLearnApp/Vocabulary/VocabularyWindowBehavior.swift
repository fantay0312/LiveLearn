import AppKit
import SwiftUI

/// SwiftUI owns the pin preference; AppKit supplies hide-on-deactivation, which has no
/// scene modifier. AppKit restores the same window and its draft when the app returns.
struct VocabularyWindowBehavior: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> VocabularyWindowBindingView {
        let view = VocabularyWindowBindingView()
        view.isPinned = isPinned
        return view
    }

    func updateNSView(_ view: VocabularyWindowBindingView, context: Context) {
        view.isPinned = isPinned
    }
}

final class VocabularyWindowBindingView: NSView {
    var isPinned = false { didSet { applyBehavior() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBehavior()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyBehavior() {
        guard let window else { return }
        window.level = isPinned ? .floating : .normal
        window.hidesOnDeactivate = !isPinned
    }
}
