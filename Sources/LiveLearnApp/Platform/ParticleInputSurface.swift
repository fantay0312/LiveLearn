import SwiftUI
import AppKit
import ParticleMath

/// A pass-through tracking surface: observes only this window and never consumes an event.
struct ParticleInputSurface: NSViewRepresentable {
    let interaction: ParticleInteraction
    var enabled: Bool

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.interaction = interaction
        view.enabled = enabled
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.interaction = interaction
        if view.enabled != enabled {
            view.enabled = enabled
            if !enabled { interaction.leave() }
            view.updateTrackingAreas()
        }
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) { view.detach() }

    final class TrackingView: NSView {
        var interaction: ParticleInteraction?
        var enabled = true
        private var area: NSTrackingArea?
        private var monitor: Any?
        private var lastMotionTime = 0.0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            area = nil
            if enabled {
                let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
                addTrackingArea(area)
                self.area = area
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            NotificationCenter.default.addObserver(self, selector: #selector(clearPointer), name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
            updateTrackingAreas()
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            interaction?.leave()
        }

        @objc private func clearPointer() { interaction?.leave() }
        override func mouseMoved(with event: NSEvent) { observe(event) }
        override func mouseEntered(with event: NSEvent) { observe(event) }
        override func mouseExited(with event: NSEvent) { interaction?.leave() }

        private func observe(_ event: NSEvent) {
            guard enabled, event.window === window, window?.isKeyWindow == true else { return }
            let now = Date.timeIntervalSinceReferenceDate
            if event.type == .mouseMoved || event.type == .leftMouseDragged {
                guard now - lastMotionTime >= 1.0 / 60 else { return }
                lastMotionTime = now
            }
            let point = convert(event.locationInWindow, from: nil)
            // Exclude the titlebar, navigation (the dock row and 6 pt above it) and the central
            // controls below the orb: the column from just above the capsule down, where Home's
            // composition puts them.
            let home = HomeComposition(windowWidth: bounds.width, windowHeight: bounds.height)
            let protected = point.y < HomeComposition.headerHeight || point.y > home.dockTop - 6 ||
                (point.y > home.windowCapsuleTop - 16 && abs(point.x - bounds.width / 2) < 260)
            guard bounds.contains(point), !protected else { interaction?.leave(); return }
            interaction?.move(to: point, dragging: event.type == .leftMouseDragged)
            if event.type == .leftMouseDown { interaction?.pulse(at: point) }
        }
    }
}

private struct ParticleInteractionKey: EnvironmentKey {
    static let defaultValue: ParticleInteraction? = nil
}

extension EnvironmentValues {
    var particleInteraction: ParticleInteraction? {
        get { self[ParticleInteractionKey.self] }
        set { self[ParticleInteractionKey.self] = newValue }
    }
}
