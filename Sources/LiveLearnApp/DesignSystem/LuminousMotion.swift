import AppKit
import SwiftUI

private struct AmbientMotionPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a surface's ambient motion should hold still without unmounting it: the main
    /// window's content sets it while the settings modal covers (and blurs) it, so the blur is
    /// rendered once instead of thirty times a second. Reading views keep their last frame.
    var ambientMotionPaused: Bool {
        get { self[AmbientMotionPausedKey.self] }
        set { self[AmbientMotionPausedKey.self] = newValue }
    }
}

/// Open windows stay alive at 12 Hz in the background; hidden pages and minimized windows stop.
///
/// `rate` is the foreground frame rate. The core and the dust run at 30; surfaces whose motion is
/// a fraction of a point per second (the wordmark) ask for less. The background rate never
/// exceeds the foreground one.
struct LuminousMotion<Content: View>: View {
    var active: Bool
    var frozenTime: Double? = nil
    var rate: Double = 30
    @ViewBuilder var content: (Double) -> Content
    @Environment(\.staticRender) private var staticRender
    @Environment(\.staticMotionTime) private var staticMotionTime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.ambientMotionPaused) private var ambientPaused
    @State private var windowVisible = false
    @State private var appActive = NSApp?.isActive ?? false
    @State private var elapsed = 0.0
    @State private var started = Date()

    /// `AmbientPower.shared` is read in the body, so a lock / unlock or a display sleep / wake
    /// re-evaluates every surface's gate (an @Observable read, not a per-instance observer).
    private var playing: Bool {
        active && windowVisible && !ambientPaused && AmbientPower.shared.screenAvailable && !staticRender && !reduceMotion && frozenTime == nil
    }

    var body: some View {
        Group {
            if let frozenTime {
                content(frozenTime)
            } else if reduceMotion {
                content(0)
            } else if staticRender {
                content(staticMotionTime)
            } else if let pinned = AmbientRendering.pinnedTime {
                // `--ambient-time`: one frame of that instant, nothing advances (the Metal layers
                // hold the same instant, so the two paths can be captured and compared).
                content(pinned)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / (appActive ? rate : min(rate, 12)), paused: !playing)) { timeline in
                    content(elapsed + (playing ? max(0, timeline.date.timeIntervalSince(started)) : 0))
                }
            }
        }
        .background {
            if !staticRender && frozenTime == nil {
                StarMapVisibility(includeOccluded: true) { windowVisible = $0 }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onChange(of: playing) { old, new in
            if old { elapsed += max(0, Date().timeIntervalSince(started)) }
            if new { started = Date() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }
}
