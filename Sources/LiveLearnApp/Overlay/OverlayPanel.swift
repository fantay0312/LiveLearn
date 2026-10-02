import AppKit
import SwiftUI
import Observation
import os

/// Layout channel between the panel controller and the SwiftUI overlay: the controller owns the
/// width, SwiftUI reports the height it needs for that width.
@MainActor
@Observable
final class OverlayLayout {
    var width: CGFloat = 600
    var onHeightChange: ((CGFloat) -> Void)?
    var pointerInside = false
    var pointerOnToolbar = false
    var controlsVisible = false
    var isLocked = false
    var isDragging = false
    var backdropIsBright = false
    static let toolbarHeight: CGFloat = 44

    func routesToControls(_ point: CGPoint) -> Bool {
        controlsVisible && point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= Self.toolbarHeight
    }

    func updatePointer(_ point: CGPoint, in frame: CGRect, visible: Bool) {
        let inside = visible && frame.contains(point)
        let onToolbar = inside && frame.maxY - point.y <= Self.toolbarHeight
        if pointerInside != inside { pointerInside = inside }
        if pointerOnToolbar != onToolbar { pointerOnToolbar = onToolbar }
        if onToolbar && !controlsVisible { controlsVisible = true }
    }

    /// Lock protects the caption body; the toolbar remains a reachable way to unlock it.
    func ignoresMouseEvents(fadingOut: Bool) -> Bool {
        fadingOut || (isLocked && !pointerOnToolbar)
    }
}

/// The toolbar takes a first click without activating the app. Only the caption body drags;
/// AppKit background dragging is disabled so native sliders and menus keep their gestures.
final class OverlayHostingView: NSHostingView<AnyView> {
    weak var layout: OverlayLayout?
    var dragWindow: ((NSEvent) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let topLeft = controlPoint(fromWindow: event.locationInWindow)
        if layout?.routesToControls(topLeft) == true {
            super.mouseDown(with: event)
            return
        }
        guard layout?.isLocked != true else { return }
        overlayLog.notice("view mouseDown → drag")
        dragWindow?(event)
    }

    func controlPoint(fromWindow point: CGPoint) -> CGPoint {
        let local = convert(point, from: nil)
        return CGPoint(x: local.x - bounds.minX, y: isFlipped ? local.y - bounds.minY : bounds.maxY - local.y)
    }
}

private let overlayLog = Logger(subsystem: "com.fantasy.livelearn", category: "overlay")

/// Non-activating floating panel hosting the overlay (doc §14.2). Normal floating level,
/// joins all Spaces and full-screen apps as an auxiliary window. Click-through is a toggle the
/// menu bar and the global hotkey can always undo.
///
/// Geometry is owned here. The panel remembers an anchor edge (bottom edge for bottom placement,
/// top edge for top placement) that only changes when the user drags the panel or the screen
/// changes. Every height update and every externally caused resize is re-applied against that
/// anchor, so the panel can never walk down the screen as captions change line count.
@MainActor
final class OverlayPanelController {
    private let model: AppModel
    private let defaults: UserDefaults
    private let layout = OverlayLayout()
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var placedOnce = false
    private var contentHeight: CGFloat = 120
    private var applyingFrame = false
    private var dragEndTask: Task<Void, Never>?
    private var contrastTask: Task<Void, Never>?
    private var backdropTone = CaptionBackdropTone()
    /// True while the panel is fading out (§6: 显示 / 隐藏 是 200ms 的透明度). A show request
    /// during the fade takes the panel back without ordering it out.
    private var fadingOut = false
    private var fadeOutTask: Task<Void, Never>?
    private var hideEpoch = UUID()
    /// Bottom placement: the y of the bottom edge. Top placement: the y of the top edge.
    private var anchorY: CGFloat?
    /// Placement the current anchor was computed for; a change moves the panel explicitly.
    private var lastPlacement: OverlayPlacement?

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
    }

    #if DEBUG
    var verificationWindow: NSPanel? { panel }
    private(set) var geometryApplicationCount = 0
    private(set) var positionSaveCount = 0
    func beginDragForVerification() { beginDragging() }
    func finishDragForVerification() { finishDragging() }
    func reportHeightForVerification(_ height: CGFloat) { applyHeight(height) }
    func revealForVerification() {
        layout.controlsVisible = true
        layout.pointerInside = true
        layout.pointerOnToolbar = true
        applyMousePolicy()
    }
    #endif

    func install() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        self.panel = panel

        layout.onHeightChange = { [weak self] height in
            self?.applyHeight(height)
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userMoved() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.externalResize() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenChanged() }
        })
        // The system-wide pointer monitor is armed only while the panel is on screen (see
        // `fadeIn` / `fadeOut`): armed at launch it woke the process on every mouse move in
        // every application, with no overlay to reveal.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.updatePointer()
            if event.type == .leftMouseUp { self?.finishDragging() }
            guard event.type == .leftMouseDown else { return event }
            guard let self, let panel = self.panel, event.window === panel, !panel.ignoresMouseEvents else { return event }
            guard let hosting = panel.contentView as? OverlayHostingView else { return event }
            let topLeft = hosting.controlPoint(fromWindow: event.locationInWindow)
            if self.layout.routesToControls(topLeft) {
                return event
            }
            guard !self.model.overlayLocked else { return nil }
            overlayLog.notice("press → drag from \(topLeft.x, format: .fixed(precision: 0)),\(topLeft.y, format: .fixed(precision: 0))")
            self.performDrag(with: event)
            return nil
        }
        observe()
    }

    // MARK: - Hosting view lifetime

    /// The SwiftUI overlay exists only while the panel is on screen. A hosting view kept alive in
    /// an ordered-out panel is not idle: its view graph kept asking AppKit for another update
    /// pass (an opacity interpolation that never lands off screen, 240–375 passes a second), and
    /// that alone held the idle process at ~21 % of a core with nothing visible — measured
    /// 2026-09-14 against a blank SwiftUI window at 0.1 % (`doc/项目实现文档.md` §5.11). So the
    /// view is built on the way in and released once the panel is out; `contentHeight` keeps the
    /// last reported height so the next show starts from a sensible frame.
    private var hostingMounted: Bool { panel?.contentView is OverlayHostingView }
    /// Set by `sync()` (inside observation tracking), consumed by `observe()` right after it.
    private var mountPending = false

    private func mountIfPending() {
        guard mountPending else { return }
        mountPending = false
        guard let panel else { return }
        mountHosting(in: panel)
    }

    private func mountHosting(in panel: NSPanel) {
        guard !hostingMounted else { return }
        let content = AnyView(
            ThemedRoot(settings: model.settings) { OverlayView() }
                .environment(model)
                .environment(layout)
        )
        let hosting = OverlayHostingView(rootView: content)
        hosting.layout = layout
        hosting.dragWindow = { [weak self] event in self?.performDrag(with: event) }
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    private func unmountHosting(from panel: NSPanel) {
        guard hostingMounted else { return }
        panel.contentView = NSView(frame: panel.contentView?.bounds ?? .zero)
    }

    private func updatePointer() {
        guard let panel else { return }
        if layout.isLocked != model.overlayLocked { layout.isLocked = model.overlayLocked }
        layout.updatePointer(NSEvent.mouseLocation, in: panel.frame, visible: panel.isVisible)
        applyMousePolicy()
    }

    private func applyMousePolicy() {
        guard let panel else { return }
        let ignore = layout.ignoresMouseEvents(fadingOut: fadingOut)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    // MARK: - Visibility

    /// Re-runs `sync()` whenever anything it read changes (overlay flags, session state, record
    /// view, placement, width). Observation replaces the former 200 ms poll, so an idle app makes
    /// no timer wake-ups for the overlay at all.
    private func observe() {
        withObservationTracking {
            sync()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        // Outside the tracking closure on purpose: building the SwiftUI hosting view must not
        // widen the set of properties `sync()` is re-run for. It lands in the same run-loop turn
        // as the `fadeIn` that asked for it, before the first display cycle.
        mountIfPending()
    }

    func sync() {
        guard let panel else { return }
        // A past record is read in the main window; the overlay is for live captions only. It
        // waits for the lanes to exist, so its first frame is a real label ("应用 · Safari"),
        // never the nameless placeholder block the preparing snapshot would show.
        let shouldShow = model.overlayVisible && !model.isViewingRecord && ((model.isActive && !model.lanes.isEmpty) || model.sessionState == .completed)
        // A panel on its way out takes no presses; the lock decides otherwise.
        if layout.isLocked != model.overlayLocked { layout.isLocked = model.overlayLocked }
        applyMousePolicy()
        let placement = model.settings.overlayPlacement
        if let last = lastPlacement, last != placement {
            // "顶部 / 底部" is an explicit move: drop the current anchor and go to that edge's
            // remembered position (or its default), even while visible.
            anchorY = nil
            if panel.isVisible {
                placeDefault()
                applyGeometry()
            } else {
                placedOnce = false
            }
        }
        lastPlacement = placement
        if shouldShow {
            if !panel.isVisible || fadingOut {
                // Mounted by `observe()` as soon as this pass returns, so the first layout pass
                // can report the real height while the panel is still fading in.
                mountPending = true
                if !placedOnce {
                    placeDefault()
                    placedOnce = true
                }
                applyGeometry()
                fadeIn(panel)
            }
            updateWidth()
        } else if panel.isVisible && !fadingOut {
            fadeOut(panel)
        }
        updatePointer()
    }

    // MARK: - Show / hide (§6: opacity, 200ms in, 150ms out; nothing under Reduce Motion)

    /// Transparent pixels may pass mouse events to the video underneath. While the panel is
    /// visible, pointer movement in either app is observed so even a fully clear top strip can
    /// reveal its controls; the monitor goes away with the panel.
    private func armGlobalPointerMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
    }

    private func watchBackdrop() {
        guard contrastTask == nil else { return }
        contrastTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.sampleBackdrop()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func sampleBackdrop() async {
        guard let panel, panel.isVisible, !panel.isMiniaturized, !layout.isDragging,
              model.settings.overlayContrastMode == .automatic, model.settings.overlayOpacity < 0.85 else { return }
        let frame = panel.frame
        guard let luminance = await CaptionBackdropSampler.luminance(below: panel),
              !Task.isCancelled, panel.isVisible, !layout.isDragging, panel.frame == frame else { return }
        let bright = backdropTone.update(luminance: luminance)
        if layout.backdropIsBright != bright { layout.backdropIsBright = bright }
    }

    private func disarmGlobalPointerMonitor() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        globalMouseMonitor = nil
    }

    private func fadeIn(_ panel: NSPanel) {
        fadeOutTask?.cancel(); fadeOutTask = nil; hideEpoch = UUID()
        let wasFading = fadingOut
        fadingOut = false
        armGlobalPointerMonitor()
        watchBackdrop()
        applyMousePolicy()
        if LLMotion.systemReducesMotion {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        if !wasFading { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = LLMotion.enterTiming
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ panel: NSPanel) {
        finishDragging()
        disarmGlobalPointerMonitor()
        contrastTask?.cancel()
        contrastTask = nil
        if LLMotion.systemReducesMotion {
            panel.orderOut(nil)
            unmountHosting(from: panel)
            return
        }
        fadingOut = true
        hideEpoch = UUID()
        let epoch = hideEpoch
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = LLMotion.exitTiming
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A show request during the fade cleared `fadingOut`; the view then stays.
                self?.finishHiding(panel, epoch: epoch)
            }
        })
        // Window-server animation completions can be delayed while another native view is
        // updating. Resource release and the close action must not depend solely on that callback.
        fadeOutTask?.cancel()
        fadeOutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            self?.finishHiding(panel, epoch: epoch)
        }
    }

    private func finishHiding(_ panel: NSPanel, epoch: UUID) {
        guard fadingOut, hideEpoch == epoch else { return }
        fadingOut = false
        panel.orderOut(nil)
        panel.alphaValue = 1
        unmountHosting(from: panel)
        fadeOutTask?.cancel(); fadeOutTask = nil
    }

    // MARK: - Geometry

    private var screen: NSScreen? { panel?.screen ?? NSScreen.main }

    private func targetWidth() -> CGFloat {
        let visible = screen?.visibleFrame.width ?? 1200
        let preferred = CGFloat(model.settings.captionDisplayWidth)
        return floor(min(preferred, visible - LLMetrics.overlayScreenMargin * 2))
    }

    private func updateWidth() {
        guard let panel, !layout.isDragging else { return }
        let width = targetWidth()
        if abs(layout.width - width) > 0.5 { layout.width = width }
        if abs(panel.frame.width - width) > 0.5 { applyGeometry() }
    }

    /// SwiftUI reports the ideal height for the current width.
    private func applyHeight(_ height: CGFloat) {
        guard height.isFinite else { return }
        let h = ceil(max(height, 44))
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        applyGeometry()
    }

    /// The single place that turns (anchor, width, content height) into a frame.
    private func applyGeometry() {
        guard let panel, !layout.isDragging else { return }
        let width = targetWidth()
        let current = panel.frame
        let x = current.midX - width / 2
        var frame = NSRect(x: x, y: current.minY, width: width, height: contentHeight)
        if let anchorY {
            switch model.settings.overlayPlacement {
            case .bottom: frame.origin.y = anchorY
            case .top: frame.origin.y = anchorY - contentHeight
            }
        }
        frame = clamped(frame)
        if frame != current {
            #if DEBUG
            geometryApplicationCount += 1
            #endif
            applyingFrame = true
            panel.setFrame(frame, display: true, animate: false)
            applyingFrame = false
        }
        // Clamping may have moved the anchor edge; keep the anchor consistent with reality.
        setAnchor(from: frame)
    }

    private func setAnchor(from frame: NSRect) {
        switch model.settings.overlayPlacement {
        case .bottom: anchorY = frame.minY
        case .top: anchorY = frame.maxY
        }
    }

    private func clamped(_ frame: NSRect) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width }
        if f.minX < visible.minX { f.origin.x = visible.minX }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height }
        if f.minY < visible.minY { f.origin.y = visible.minY }
        return f
    }

    private func placeDefault() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = targetWidth()
        var frame: NSRect
        if let saved = savedOrigin(for: screen) {
            frame = NSRect(x: saved.x, y: saved.y, width: width, height: contentHeight)
        } else {
            let x = visible.midX - width / 2
            let y: CGFloat
            switch model.settings.overlayPlacement {
            case .bottom: y = visible.minY + LLMetrics.overlayBottomOffset
            case .top: y = visible.maxY - LLMetrics.overlayBottomOffset - contentHeight
            }
            frame = NSRect(x: x, y: y, width: width, height: contentHeight)
        }
        frame = clamped(frame)
        applyingFrame = true
        panel.setFrame(frame, display: false)
        applyingFrame = false
        setAnchor(from: frame)
    }

    private func performDrag(with event: NSEvent) {
        guard let panel, !layout.isDragging, !model.overlayLocked else { return }
        beginDragging()
        panel.performDrag(with: event)
        // Window Server owns the drag. performDrag returns immediately and may consume the
        // mouse-up, so observe the physical button until release instead of resizing early.
        dragEndTask?.cancel()
        dragEndTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(32)) } catch { return }
                guard let self, self.layout.isDragging else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 { self.finishDragging(); return }
            }
        }
    }

    private func beginDragging() {
        layout.isDragging = true
    }

    private func finishDragging() {
        guard layout.isDragging, let panel else { return }
        dragEndTask?.cancel()
        dragEndTask = nil
        setAnchor(from: panel.frame)
        layout.isDragging = false
        updateWidth()
        applyGeometry()
        if let screen = panel.screen {
            let origin = panel.frame.origin
            defaults.set([origin.x, origin.y], forKey: screenKey(screen))
            #if DEBUG
            positionSaveCount += 1
            #endif
        }
    }

    /// Movement notifications only update the anchor; a completed drag saves it once.
    private func userMoved() {
        guard !applyingFrame, let panel, panel.isVisible else { return }
        setAnchor(from: panel.frame)
    }

    /// Anything else that resized the panel (AppKit fitting the content view, a system event):
    /// put it back on the anchor with the height we know.
    private func externalResize() {
        guard !applyingFrame, !layout.isDragging, let panel, panel.isVisible else { return }
        if abs(panel.frame.height - contentHeight) > 0.5 || abs(panel.frame.width - targetWidth()) > 0.5 {
            applyGeometry()
        }
    }

    private func screenChanged() {
        guard let panel, panel.isVisible, !layout.isDragging else { return }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen {
            anchorY = nil
            placeDefault()
        }
        applyGeometry()
    }

    // MARK: - Per-screen, per-placement position memory (§9.2)

    /// A dragged position belongs to the placement it was dragged under, so switching to
    /// "顶部" never reuses a spot the user chose for "底部".
    private func screenKey(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
        return "LiveLearn.overlay.origin.\(id).\(model.settings.overlayPlacement.rawValue)"
    }

    private func savedOrigin(for screen: NSScreen) -> CGPoint? {
        guard let arr = defaults.array(forKey: screenKey(screen)) as? [Double], arr.count == 2 else { return nil }
        return CGPoint(x: arr[0], y: arr[1])
    }

    func capture(to url: URL) -> Bool { WindowCapture.write(panel, to: url) }

    func captureBackdrop(_ color: NSColor, to url: URL) async -> Bool {
        guard let panel else { return false }
        let original = panel.backgroundColor
        let expectedBright = (color.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.5
        let backdrop = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.isFloatingPanel = true
        backdrop.hidesOnDeactivate = false
        backdrop.collectionBehavior = panel.collectionBehavior
        backdrop.backgroundColor = color
        backdrop.isOpaque = true
        backdrop.ignoresMouseEvents = true
        backdrop.level = panel.level
        backdrop.order(.below, relativeTo: panel.windowNumber)
        defer { panel.backgroundColor = original; backdrop.close() }
        panel.backgroundColor = color
        panel.displayIfNeeded()
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(350))
            if layout.backdropIsBright == expectedBright { break }
        }
        let luminance = await CaptionBackdropSampler.luminance(below: panel)
        print("backdrop sample: \(luminance ?? -1), bright ink mode: \(layout.backdropIsBright), expected: \(expectedBright)")
        guard layout.backdropIsBright == expectedBright else { return false }
        return WindowCapture.write(panel, to: url)
    }
}
