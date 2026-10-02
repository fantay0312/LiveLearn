import AppKit
import Testing
@testable import LiveLearnApp

@MainActor
struct VocabularyWindowBehaviorTests {
    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    }

    @Test func unpinChangesTheNativeWindowAndRetainsItsContent() {
        let window = window()
        let view = VocabularyWindowBindingView()
        window.contentView = view
        #expect(window.level == .normal && window.hidesOnDeactivate)
        view.isPinned = true
        #expect(window.level == .floating && !window.hidesOnDeactivate)
        view.isPinned = false
        #expect(window.level == .normal && window.hidesOnDeactivate)
        #expect(window.contentView === view)
        #expect(window.styleMask.contains(.miniaturizable))
        #expect(!window.isVisible, "Updating the preference must not bring a background window forward")
    }

    @Test func attachingToARecreatedWindowReappliesTheCurrentPreference() {
        let first = window(), second = window()
        let view = VocabularyWindowBindingView()
        view.isPinned = true
        first.contentView = view
        #expect(first.level == .floating)
        view.removeFromSuperview()
        view.isPinned = false
        second.level = .floating
        second.hidesOnDeactivate = false
        second.contentView = view
        #expect(second.level == .normal && second.hidesOnDeactivate)
        #expect(view.hitTest(.zero) == nil)
    }
}
