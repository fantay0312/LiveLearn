import AppKit
import QuartzCore
import OSLog

/// The clock of one `LuminousMotion` surface, kept the same way: time is the accumulated
/// playing time, it does not advance while paused, and a resumed surface continues from where it
/// stopped without a catch-up burst. `--ambient-time` pins it.
struct AmbientClock {
    private(set) var elapsed = 0.0
    private(set) var started = Date()
    private(set) var playing = false

    mutating func set(playing new: Bool) {
        guard new != playing else { return }
        if playing { elapsed += max(0, Date().timeIntervalSince(started)) }
        if new { started = Date() }
        playing = new
    }

    func time(at now: Date) -> Double {
        AmbientRendering.pinnedTime ?? (elapsed + (playing ? max(0, now.timeIntervalSince(started)) : 0))
    }
}

/// An `NSView` whose layer is a `CAMetalLayer`, with the frame clock and the gates of
/// `LuminousMotion`: it renders at 30 Hz while the app is active and 12 Hz otherwise, only while
/// the window is visible and not miniaturized (an occluded window keeps running, like
/// `StarMapVisibility(includeOccluded: true)`), the surface is `active`, ambient motion is not
/// paused and Reduce Motion is off. When a gate closes the last drawable stays on screen and the
/// clock stops; a parameter or size change while stopped renders exactly one frame at the frozen
/// time, as a Canvas would re-render. Subclasses own their clocks and geometry.
@MainActor
class ParticleMetalHostView: NSView {
    let renderer: ParticleMetalRenderer
    let inFlight = DispatchSemaphore(value: ParticleMetalRenderer.framesInFlight)
    var ambientPaused = false { didSet { if oldValue != ambientPaused { refreshPlaying() } } }
    var reduceMotion = false { didSet { if oldValue != reduceMotion { refreshPlaying() } } }
    private(set) var windowVisible = false
    private(set) var appActive = NSApp.isActive
    private(set) var playing = false
    private var link: CADisplayLink?
    var frameDriverPaused: Bool { link?.isPaused ?? true }
    private var lastRenderAt = -1.0
    private var needsFrame = false
    private static let logger = Logger(subsystem: "com.fantasy.livelearn", category: "AmbientRendering")
    private var tracedTicks = 0
    private var tracedFrames = 0
    private var lastTraceAt = CACurrentMediaTime()

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(renderer: ParticleMetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        // Only the observers: a live `CADisplayLink` retains its target, so reaching `deinit` at
        // all is the proof that the link is already invalidated — `detach()` ran, from
        // `viewWillMove(toWindow: nil)` or from `dismantleNSView`. A host that ever left its
        // window by any other path would never get here at all and would keep ticking forever,
        // so `detach()` is the invariant to keep, not anything written here. (`deinit` is
        // nonisolated and `link` is main-actor state, so it cannot be asserted from here.)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Subclass hooks

    /// Applies the shared gate to the subclass's clocks; returns whether any of them plays.
    func applyGate(_ open: Bool) -> Bool { false }
    /// Builds and draws the frame for `now`.
    func render(at now: Date) {}
    /// The drawable was resized: offscreen textures sized to it are stale.
    func drawableSizeDidChange() {}

    // MARK: Layer

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm            // not _srgb: blending stays in gamma space, as in the canvases
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.backgroundColor = nil
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        layer.maximumDrawableCount = 3
        return layer
    }

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    // MARK: Window

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { detach() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A move between windows: the old link (which retains its target) and observers go first.
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            windowVisible = false
            refreshPlaying()
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(self, selector: #selector(windowStateChanged), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(appBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(powerChanged), name: AmbientPower.didChange, object: nil)
        appActive = NSApp.isActive
        updateScale()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
        applyRate()
        // A move straight from one window to another keeps `windowVisible` true, and the new
        // link starts paused: start from "not visible" so the gate is re-evaluated either way.
        windowVisible = false
        refreshVisibility()
        requestFrame()
        traceState("attached")
    }

    /// Stops the display link (which retains its target) and the observers; called when the
    /// view leaves its window and when SwiftUI dismantles it.
    func detach() {
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
        windowVisible = false
        refreshPlaying()
        traceState("detached")
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        applyRate()   // the window may have moved to a display with other refresh limits
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        if scale > 0, metalLayer.contentsScale != scale { metalLayer.contentsScale = scale }
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = metalLayer.contentsScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            drawableSizeDidChange()
            // Drawn now, not at the next tick: a stale drawable stretched to the new size would
            // show for a frame during a live resize, where the Canvas re-renders in layout.
            renderIfPossible()
        }
    }

    @objc private func windowStateChanged() {
        refreshVisibility()
        // Frames are not presented while the window is fully covered; catch up as soon as it
        // shows — at the next tick when playing, right now when the clock is stopped (a stopped
        // layer that was never drawn, or was covered when its parameters changed, has nothing
        // else to draw it).
        if window?.occlusionState.contains(.visible) == true { requestFrame() }
    }

    @objc private func appBecameActive() {
        appActive = true
        applyRate()
        refreshVisibility()
        requestFrame()
    }

    @objc private func appResignedActive() {
        appActive = false
        applyRate()
    }

    /// The session locked or the displays slept (or came back): nothing can be seen, so the
    /// gate closes like a paused one; on return the layer draws once and resumes its clock.
    @objc private func powerChanged() {
        refreshPlaying()
        if AmbientPower.shared.screenAvailable { requestFrame() }
    }

    private func refreshVisibility() {
        windowVisible = window.map { $0.isVisible && !$0.isMiniaturized } ?? false
        refreshPlaying()
    }

    // MARK: Clock

    /// The frame rate while the app is active (`LuminousMotion.rate`): 30 for the core, the dust
    /// and most surfaces, less for one whose motion is a fraction of a point per second (the
    /// wordmark asks for 15). The background rate never exceeds it.
    var foregroundRate: Double = 30 {
        didSet { if oldValue != foregroundRate { applyRate() } }
    }

    /// The rate in force: `LuminousMotion`'s `appActive ? rate : min(rate, 12)`.
    var rate: Double { appActive ? foregroundRate : min(foregroundRate, 12) }

    func refreshPlaying() {
        let open = windowVisible && !ambientPaused && !reduceMotion && window != nil && AmbientPower.shared.screenAvailable
        // A pinned clock (`--ambient-time`) draws its one instant on demand and never ticks, as
        // the pinned `LuminousMotion` renders its content once.
        // `--ambient-probe no-links` (development) holds every clock stopped, so the layer draws
        // the one frame `requestFrame()` asks for and no link ever runs.
        let now = applyGate(open) && AmbientRendering.pinnedTime == nil && !AmbientRendering.noLinks
        let changed = now != playing
        let driverWasPaused = frameDriverPaused
        playing = now
        // A replacement link starts paused even when the logical gate never closed.
        // Always synchronize the actual driver before skipping unchanged state.
        link?.isPaused = !now
        if now && (changed || driverWasPaused) {
            lastRenderAt = -1
            needsFrame = true
        }
        if changed || (now && driverWasPaused) { traceState("gate") }
    }

    /// Something visible changed: draw at the next tick when playing, or once now at the frozen
    /// time when not (the Canvas re-renders on a parameter change even while its clock is paused).
    func requestFrame() {
        if playing {
            needsFrame = true
        } else {
            renderIfPossible()
        }
    }

    private func applyRate() {
        guard let link else { return }
        var hz = Float(rate)
        if let screen = window?.screen, screen.maximumRefreshInterval > 0, screen.minimumRefreshInterval > 0 {
            hz = min(max(hz, Float(1 / screen.maximumRefreshInterval)), Float(1 / screen.minimumRefreshInterval))
        }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard playing else { return }
        let now = CACurrentMediaTime()
        if AmbientRendering.trace {
            tracedTicks += 1
            if now - lastTraceAt >= 5 {
                Self.logger.info("\(String(describing: type(of: self)), privacy: .public) ticks=\(self.tracedTicks) frameAttempts=\(self.tracedFrames) rate=\(self.rate) paused=\(self.frameDriverPaused)")
                lastTraceAt = now
            }
        }
        // The same throttle as `TimelineView(.animation(minimumInterval:))`: a frame every
        // `1 / rate` seconds, whichever the display's own rate is.
        if !needsFrame, lastRenderAt >= 0, now - lastRenderAt < 1 / rate - 0.002 { return }
        needsFrame = false
        lastRenderAt = now
        renderIfPossible()
    }

    private func renderIfPossible() {
        guard let window, bounds.width >= 1, bounds.height >= 1, metalLayer.drawableSize.width >= 1 else { return }
        // A fully covered window has nothing to show; its clock keeps running regardless.
        guard window.occlusionState.contains(.visible) || AmbientRendering.pinnedTime != nil else { return }
        // `--ambient-probe ticks-only` (development): the links keep ticking, nothing is built
        // or presented, so a measurement can separate the two costs.
        guard !AmbientRendering.ticksOnly else { return }
        if AmbientRendering.trace { tracedFrames += 1 }
        render(at: Date())
        if !loggedFirstFrame, AmbientRendering.pinnedTime != nil {
            // A capture run (`--ambient-time`) says which layers took the GPU path, and at what size.
            loggedFirstFrame = true
            let size = metalLayer.drawableSize
            FileHandle.standardError.write(Data("ambient metal layer \(type(of: self)): first frame \(Int(size.width))×\(Int(size.height)) px at scale \(metalLayer.contentsScale)\n".utf8))
        }
    }
    private var loggedFirstFrame = false

    private func traceState(_ reason: String) {
        guard AmbientRendering.trace else { return }
        Self.logger.info("\(String(describing: type(of: self)), privacy: .public) \(reason, privacy: .public) playing=\(self.playing) driverPaused=\(self.frameDriverPaused) visible=\(self.windowVisible) ambientPaused=\(self.ambientPaused) reduceMotion=\(self.reduceMotion) screenAvailable=\(AmbientPower.shared.screenAvailable)")
    }
}
