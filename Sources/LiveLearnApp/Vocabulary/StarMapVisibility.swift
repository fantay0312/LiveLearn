import AppKit
import SwiftUI

/// SwiftUI keeps the vocabulary page mounted. Observe only its own window's visibility.
struct StarMapVisibility: NSViewRepresentable {
    var includeOccluded = false
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.includeOccluded = includeOccluded
        view.changed = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.includeOccluded = includeOccluded
        view.changed = onChange
    }

    final class ObserverView: NSView {
        var changed: ((Bool) -> Void)?
        var includeOccluded = false
        private var lastValue: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: window)
                }
            }
            refresh()
        }

        @objc private func refresh() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let visible = window.map { $0.isVisible && !$0.isMiniaturized && (includeOccluded || $0.occlusionState.contains(.visible)) } ?? false
                guard visible != lastValue else { return }
                lastValue = visible
                changed?(visible)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
