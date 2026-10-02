import AppKit
import CoreGraphics

enum ModifierShortcut: UInt16, CaseIterable, Sendable {
    case rightCommand = 54, command = 55, shift = 56, option = 58, control = 59
    case rightShift = 60, rightOption = 61, rightControl = 62, fn = 63

    var title: String {
        switch self {
        case .fn: "Fn"
        case .option: "左 Option"
        case .rightOption: "右 Option"
        case .control: "左 Control"
        case .rightControl: "右 Control"
        case .shift: "左 Shift"
        case .rightShift: "右 Shift"
        case .command: "左 Command"
        case .rightCommand: "右 Command"
        }
    }

    private var bits: (own: UInt64, family: UInt64, aggregate: CGEventFlags) {
        // Device-specific masks from Apple's IOLLEvent.h distinguish releasing one side
        // while the opposite modifier remains held.
        switch self {
        case .control: (0x1, 0x2001, .maskControl)
        case .rightControl: (0x2000, 0x2001, .maskControl)
        case .shift: (0x2, 0x6, .maskShift)
        case .rightShift: (0x4, 0x6, .maskShift)
        case .command: (0x8, 0x18, .maskCommand)
        case .rightCommand: (0x10, 0x18, .maskCommand)
        case .option: (0x20, 0x60, .maskAlternate)
        case .rightOption: (0x40, 0x60, .maskAlternate)
        case .fn: (0x800000, 0x800000, .maskSecondaryFn)
        }
    }

    func isDown(flags: UInt64) -> Bool {
        let b = bits
        return flags & b.family != 0 ? flags & b.own != 0 : flags & b.aggregate.rawValue != 0
    }
}

/// Defers accepting a lone modifier until release, so Option then A still records Option+A.
struct ShortcutRecordingState {
    private var candidate: ModifierShortcut?
    private var pressed: Set<ModifierShortcut> = []
    private var chord = false

    mutating func consume(_ event: NSEvent) -> KeyCombo? {
        if event.type == .keyDown {
            chord = true; candidate = nil
            if pressed.contains(.fn), !KeyCombo(keyCode: event.keyCode, modifiers: 0).isFunctionKey { return nil }
            return KeyCombo(event: event)
        }
        guard event.type == .flagsChanged, let key = ModifierShortcut(rawValue: event.keyCode) else { return nil }
        if key.isDown(flags: UInt64(event.modifierFlags.rawValue)) {
            if pressed.isEmpty { candidate = key; chord = false }
            else if !pressed.contains(key) { chord = true; candidate = nil }
            pressed.insert(key)
            return nil
        }
        let wasPressed = pressed.remove(key) != nil
        let result = wasPressed && !chord && candidate == key ? KeyCombo(keyCode: key.rawValue, modifiers: 0) : nil
        if pressed.isEmpty { candidate = nil; chord = false }
        return result
    }
}
