import AppKit
import CoreGraphics
import Observation
import Carbon

@MainActor @Observable
final class ModifierKeyMonitor {
    let key: ModifierShortcut
    private let fireOnPress: Bool
    private(set) var unavailable = false
    @ObservationIgnored var onPress: (() -> Void)?
    @ObservationIgnored var onRelease: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var pressed = false
    @ObservationIgnored private var usedInChord = false
    @ObservationIgnored private var generation = UUID()

    init(key: ModifierShortcut = .fn, fireOnPress: Bool = true) { self.key = key; self.fireOnPress = fireOnPress }

    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); unavailable = false; return }
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                Unmanaged<ModifierKeyMonitor>.fromOpaque(pointer).takeUnretainedValue().handle(type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: pointer) else { unavailable = true; return }
        self.tap = tap
        generation = UUID()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        unavailable = false
    }

    private func handle(_ type: CGEventType, keyCode: Int64, flags: UInt64) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            Task { @MainActor [weak self] in self?.onCancel?() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let otherModifierDown = type == .flagsChanged && keyCode != Int64(key.rawValue) && UInt16(exactly: keyCode).flatMap(ModifierShortcut.init(rawValue:))?.isDown(flags: flags) == true
        if pressed && (type == .keyDown || otherModifierDown) {
            usedInChord = true; generation = UUID()
            Task { @MainActor [weak self] in self?.onCancel?() }
            return false
        }
        guard type == .flagsChanged, keyCode == Int64(key.rawValue) else { return false }
        guard !HotKeyCenter.shared.suspended, !IsSecureEventInputEnabled() else {
            if pressed { reset(); Task { @MainActor [weak self] in self?.onCancel?() } }
            return false
        }
        let down = key.isDown(flags: flags)
        if pressed != down {
            pressed = down
            if down { usedInChord = false }
            let chord = usedInChord
            let id = generation
            // Never do audio/AX work inside the event-tap callback: macOS disables slow taps.
            Task { @MainActor [weak self] in
                guard let self, self.tap != nil, self.generation == id else { return }
                guard !chord else { return }
                if down { if self.fireOnPress { self.onPress?() } }
                else {
                    if !self.fireOnPress { self.onPress?() }
                    self.onRelease?()
                }
            }
        }
        return true
    }

    func reset() { pressed = false; usedInChord = false; generation = UUID() }
    func stop() {
        let wasPressed = pressed
        reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if wasPressed { onCancel?() }
    }
}
