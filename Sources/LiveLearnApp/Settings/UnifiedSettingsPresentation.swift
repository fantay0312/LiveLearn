import AppKit
import Observation

/// One main-window modal owns every settings page, including Easydict's native content.
@MainActor
@Observable
final class UnifiedSettingsPresentation {
    static let shared = UnifiedSettingsPresentation()
    private(set) var isPresented = false
    private(set) var translationSection: Int?
    private(set) var translationSectionRequestID = UUID()
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private weak var previousResponder: NSResponder?
    @ObservationIgnored private var settings: AppSettings?
    @ObservationIgnored private var openMainWindow: (() -> Void)?

    func configure(settings: AppSettings, openMainWindow: @escaping () -> Void) {
        self.settings = settings
        self.openMainWindow = openMainWindow
        TranslationFeature.shared.onSettingsNavigation = { [weak self] in self?.receive($0) }
    }

    func register(_ window: NSWindow) {
        self.window = window
        if isPresented { bringHostForward() }
    }

    func open(waitForHost: Bool = false) {
        if !isPresented {
            previousResponder = window?.firstResponder
            window?.makeFirstResponder(nil)
        }
        isPresented = true
        if !waitForHost || window != nil { bringHostForward() }
    }

    func dismiss() {
        isPresented = false
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }

    func hostClosed() {
        dismiss()
        window = nil
    }

    func showTranslation(section: Int? = nil) {
        if let section {
            translationSection = section
            translationSectionRequestID = UUID()
        }
        settings?.requestedSettingsTab = .textTranslation
        open()
    }

    private func bringHostForward() {
        guard let window else { openMainWindow?(); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func receive(_ reply: TranslationReply) {
        guard let name = reply.settingsPage, let page = LiveLearnSettingsPage(rawValue: name) else { return }
        if page == .textTranslation { showTranslation(section: reply.settingsSection) }
        else {
            settings?.requestedSettingsTab = page.settingsTab
            open()
        }
    }
}
