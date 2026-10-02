#if DEBUG
import AppKit
import OSLog

/// Opt-in diagnostics for window-management regressions. No vocabulary or document data.
@MainActor
enum VocabularyWindowTrace {
    private static let logger = Logger(subsystem: "com.fantasy.livelearn", category: "VocabularyWindow")
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let event = note.name.rawValue
                MainActor.assumeIsolated { record(event: event) }
            })
        }
    }

    private static func record(event: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "vocabulary" }) else { return }
        logger.info("VocabularyWindow event=\(event, privacy: .public) active=\(NSApp.isActive) level=\(window.level.rawValue) behavior=\(window.collectionBehavior.rawValue) hideOnDeactivate=\(window.hidesOnDeactivate) visible=\(window.isVisible) unobscured=\(window.occlusionState.contains(.visible)) minimized=\(window.isMiniaturized)")
    }
}
#endif
