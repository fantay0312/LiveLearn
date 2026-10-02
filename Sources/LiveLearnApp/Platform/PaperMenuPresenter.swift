import AppKit
import SwiftUI

/// Shows one `PaperMenuSheet` at a time in a borderless child window under its label, and
/// takes it down on anything that would leave it stranded: a click or scroll outside it, Esc,
/// the window moving, resizing or losing key, the app deactivating.
///
/// The window is a non-activating panel: the main window stays key, so clicking a row never
/// dims the title bar or steals focus from a field. Keys reach the sheet through a local event
/// monitor while it is open (arrows, return, Esc); everything else passes through untouched.
@MainActor
final class PaperMenuPresenter {
    static let shared = PaperMenuPresenter()

    private var panel: PaperMenuPanel?
    private var hosting: PaperMenuHostingView?
    private weak var parent: NSWindow?
    private var session: PaperMenuSession?
    /// The label's frame in screen coordinates: a click on it while open closes the sheet
    /// without reopening it.
    private var anchorRect = CGRect.zero
    private var placeAbove = false
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onDismiss: (() -> Void)?
    private var menuContent: AnyView?
    private var contentScale: CGFloat = 1
    private var requestedScale: CGFloat = 1

    private init() {}

    var isOpen: Bool { panel != nil }

    func present(anchor: NSView, environment: EnvironmentValues, columns: @escaping () -> [PaperMenuColumn], onDismiss: @escaping () -> Void) {
        dismiss()
        guard let window = anchor.window, let screen = window.screen ?? NSScreen.main else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        anchorRect = rect
        parent = window
        self.onDismiss = onDismiss

        let session = PaperMenuSession(columns: columns) { [weak self] item in
            self?.activate(item)
        }
        self.session = session
        // Opened from the keyboard (space / return on the focused label): start on the chosen
        // row, so ↓ continues from it instead of from the top.
        session.highlightChosen()

        // Room below the label, or above it if that is the larger side; the column cap keeps the
        // sheet inside the visible screen either way.
        let visible = screen.visibleFrame
        let below = rect.minY - visible.minY - 12
        let above = visible.maxY - rect.maxY - 12
        placeAbove = below < 240 && above > below
        contentScale = environment.interfaceScale
        requestedScale = contentScale
        let cap = max(80, min(380, (placeAbove ? above : below) / contentScale - 40))

        let root = ThemedRoot { PaperMenuSheet(session: session, columnHeightCap: cap) }
            .environment(\.self, environment)
        menuContent = AnyView(root)
        let hosting = PaperMenuHostingView(rootView: AnyView(root))
        let size = scaledSize(of: hosting, in: visible)
        hosting.frame = CGRect(origin: .zero, size: size)
        self.hosting = hosting

        let panel = PaperMenuPanel(contentRect: CGRect(origin: .zero, size: size))
        panel.contentView = hosting
        self.panel = panel
        place(size: size, visible: visible)

        window.addChildWindow(panel, ordered: .above)
        // §6: the sheet fades in over 180ms and slides the last 4pt from the label into place
        // (down when it opens below the label, up when above). Opacity and position only.
        let final = panel.frame
        if LLMotion.systemReducesMotion {
            panel.alphaValue = 1
            panel.orderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.setFrame(final.offsetBy(dx: 0, dy: placeAbove ? -4 : 4), display: false)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = LLMotion.enterTiming
                panel.animator().alphaValue = 1
                panel.animator().setFrame(final, display: true)
            }
        }
        install(window: window)
    }

    /// Synchronous and idempotent: the presenter forgets the sheet at once (a new `present()`
    /// may follow in the same turn). A pointer-initiated close lets the old panel fade out over
    /// 120ms; a keyboard close, and every close the window itself causes, is instant.
    func dismiss(animated: Bool = true) {
        guard let panel else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        let parent = self.parent
        self.panel = nil
        hosting = nil
        session = nil
        menuContent = nil
        self.parent = nil
        let done = onDismiss
        onDismiss = nil
        if !animated || LLMotion.systemReducesMotion {
            Self.takeDown(panel, from: parent)
        } else {
            panel.ignoresMouseEvents = true
            // The completion is called back on the main thread; the panel and its parent are
            // handed over through a Sendable box so the compiler agrees.
            let box = WindowBox(panel: panel, parent: parent)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = LLMotion.exitTiming
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { Self.takeDown(box.panel, from: box.parent) }
            })
        }
        done?()
    }

    private static func takeDown(_ panel: NSPanel, from parent: NSWindow?) {
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// AppKit windows are main-thread objects; this box only crosses into a completion handler
    /// that AppKit invokes on the main thread.
    private struct WindowBox: @unchecked Sendable {
        let panel: NSPanel
        weak var parent: NSWindow?
    }

    // MARK: Placement

    /// The sheet's card sits 4pt under the label with its rows' text starting where the label's
    /// text starts (the card is inset by the row padding), clamped to the visible screen.
    private func place(size: CGSize, visible: CGRect) {
        guard let panel else { return }
        let pad = PaperMenuSheet.shadowPad * contentScale
        let card = CGSize(width: size.width - 2 * pad, height: size.height - 2 * pad)
        var x = anchorRect.minX - (PaperMenuSheet.inset + PaperMenuSheet.textInset) * contentScale
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - card.width - 8))
        var y: CGFloat
        if placeAbove {
            y = anchorRect.maxY + 4
        } else {
            y = anchorRect.minY - 4 - card.height
        }
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - card.height - 8))
        panel.setFrame(CGRect(x: x - pad, y: y - pad, width: size.width, height: size.height), display: true)
    }

    /// After an action that keeps the sheet open (a tick, a source language, 刷新列表), the
    /// rows may have changed; measure again and keep the edge nearest the label where it was.
    private func relayout() {
        guard let hosting, let panel, let screen = parent?.screen ?? NSScreen.main else { return }
        let size = scaledSize(of: hosting, in: screen.visibleFrame)
        guard size != panel.frame.size else { return }
        hosting.frame = CGRect(origin: .zero, size: size)
        place(size: size, visible: screen.visibleFrame)
    }

    private func scaledSize(of hosting: PaperMenuHostingView, in screen: CGRect) -> CGSize {
        guard let menuContent else { return hosting.fittingSize }
        hosting.rootView = menuContent
        let logical = hosting.fittingSize
        contentScale = min(requestedScale, (screen.width - 16) / max(1, logical.width))
        let size = CGSize(width: logical.width * contentScale, height: logical.height * contentScale)
        hosting.rootView = AnyView(menuContent.frame(width: logical.width, height: logical.height)
            .scaleEffect(contentScale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading))
        return size
    }

    // MARK: Actions

    /// Runs after the row's click has finished dispatching: the button that was pressed lives
    /// in the hosting view that `dismiss()` tears down, so the teardown waits one turn.
    private func activate(_ item: PaperMenuItem) {
        guard item.isInteractive else { return }
        let action = item.action
        let animated = NSApp.currentEvent?.type != .keyDown
        if item.keepsOpen {
            DispatchQueue.main.async { [weak self] in
                action?()
                self?.relayout()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.dismiss(animated: animated)
                action?()
            }
        }
    }

    // MARK: Watching

    private func install(window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(animated: false) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        })

        // Local monitors run on the main thread; the closures are formed here on the main actor
        // and keep its isolation.
        let mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            return self.mouseDown(event)
        })
        let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss() }
            return event
        })
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            return self.keyDown(event)
        })
        monitors = [mouse, scroll, keys].compactMap { $0 }
    }

    /// A click inside the sheet is the sheet's; a click on the label closes the sheet and is
    /// swallowed (else the label would open it again); any other click closes it and goes on
    /// to whatever it hit.
    private func mouseDown(_ event: NSEvent) -> NSEvent? {
        guard let panel else { return event }
        if event.window === panel { return event }
        var location = event.locationInWindow
        if let w = event.window { location = w.convertPoint(toScreen: location) }
        let onLabel = anchorRect.insetBy(dx: -4, dy: -4).contains(location)
        dismiss()
        return onLabel ? nil : event
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        guard let session else { return event }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        switch event.keyCode {
        case 53: // Esc
            dismiss(animated: false)
            return nil
        case 48: // Tab: the sheet closes and focus moves on to the next control as usual.
            dismiss(animated: false)
            return event
        case 125: session.move(by: 1); return nil    // ↓
        case 126: session.move(by: -1); return nil   // ↑
        case 123: session.moveColumn(by: -1); return nil // ←
        case 124: session.moveColumn(by: 1); return nil  // →
        case 36, 76, 49: // ⏎, enter, space
            session.activateHighlighted()
            return nil
        default:
            return event
        }
    }
}

/// Borderless, non-activating, transparent: the sheet draws its own paper, its lit edge and, in
/// the light theme, its one shadow (`floatingPaper`), inside the `shadowPad` margin.
private final class PaperMenuPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click even though its window is never key.
private final class PaperMenuHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
