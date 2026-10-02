import AppKit
import Foundation
import Observation

/// Whether anything on this machine's screens can be seen at all. Ambient motion keeps running
/// behind other windows (a user decision: the sky is alive when the window comes back), but a
/// locked session or a sleeping display shows nobody anything, and a 30 Hz sky behind the lock
/// screen was measured at more than a third of a core. Every ambient clock — `LuminousMotion`,
/// the Metal particle layers, the top bar's sound lines — treats `screenAvailable == false`
/// like a closed gate: the last frame stays, time stops, and it resumes where it was.
@MainActor @Observable
final class AmbientPower {
    static let shared = AmbientPower()
    static let didChange = Notification.Name("LiveLearn.AmbientPower.didChange")

    private(set) var screenAvailable = true
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (AmbientPower) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    change(self)
                    self.publish()
                }
            })
        }
        watch(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        watch(workspace, NSWorkspace.screensDidWakeNotification) { $0.asleep = false }
        watch(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        watch(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }
        watch(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        watch(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    private func publish() {
        let available = !locked && !asleep && !sessionInactive
        guard available != screenAvailable else { return }
        screenAvailable = available
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
