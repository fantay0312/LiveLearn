import AppKit
import Carbon
import Foundation
import SwiftUI
import Testing
@testable import LiveLearnApp

@MainActor
struct HotKeyTests {
    private func isolated() -> (UserDefaults, String) {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func comboPrintsModifiersInSystemOrderAndNamesSpecialKeys() {
        let all = KeyCombo(keyCode: kVK_ANSI_S, flags: [.command, .shift, .option, .control])
        #expect(all.modifierGlyphs == "⌃⌥⇧⌘")
        #expect(all.display.hasPrefix("⌃⌥⇧⌘"))
        #expect(KeyCombo(keyCode: kVK_Return, flags: [.control, .option, .command]).display == "⌃⌥⌘↩")
        #expect(KeyCombo(keyCode: kVK_F5, flags: []).display == "F5")
        #expect(KeyCombo(keyCode: kVK_Space, flags: [.command]).display == "⌘空格")
        #expect(KeyCombo(keyCode: kVK_Escape, flags: []).display == "⎋")
    }

    @Test func acceptabilityAllowsSingleKeysAndCombinations() {
        #expect(KeyCombo(keyCode: kVK_ANSI_S, flags: []).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_ANSI_S, flags: [.shift]).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_ANSI_S, flags: [.command]).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_ANSI_S, flags: [.control]).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_ANSI_S, flags: [.option, .shift]).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_F5, flags: []).isAcceptable)
        #expect(KeyCombo(keyCode: kVK_F19, flags: [.shift]).isAcceptable)
    }

    @Test func modifierMaskRoundTripsThroughCarbonAndBack() {
        let flags: NSEvent.ModifierFlags = [.command, .control]
        let combo = KeyCombo(keyCode: kVK_ANSI_L, flags: flags)
        #expect(combo.modifiers == UInt32(cmdKey | controlKey))
        #expect(combo.flags == flags)
        #expect(KeyCombo(stored: combo.stored) == combo)
        #expect(KeyCombo(stored: [1]) == nil)
        #expect(KeyCombo(stored: [-1, 0]) == nil)
        #expect(KeyCombo(stored: [37, Int(UInt32.max) + 1]) == nil)
        #expect(KeyCombo(stored: [Int(UInt16.max) + 1, 0]) == nil)
        // Unknown bits (caps lock, function) are dropped so a stored value never carries them.
        #expect(KeyCombo(keyCode: 0, modifiers: 0xFFFF_FFFF).modifiers == KeyCombo.allModifiers)
    }

    @Test func nothingShipsBoundAndCarbonIDsAreStable() {
        let (defaults, suite) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for action in HotKeyAction.allCases { #expect(settings.hotKey(for: action) == nil) }
        #expect(settings.hotKeyBindings.isEmpty)
        // Carbon ids are stable, distinct and non-zero.
        #expect(Set(HotKeyAction.allCases.map(\.carbonID)).count == HotKeyAction.allCases.count)
        #expect(HotKeyAction.allCases.allSatisfy { $0.carbonID > 0 })
    }

    @Test func settingsRememberSetAndClearedCombinations() {
        let (defaults, suite) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        // A combination is remembered across launches.
        let custom = KeyCombo(keyCode: kVK_ANSI_P, flags: [.command, .option])
        settings.setHotKey(custom, for: .togglePause)
        #expect(AppSettings(defaults: defaults).hotKey(for: .togglePause) == custom)
        #expect(settings.hotKeyBindings == [.togglePause: custom])

        // Clearing removes the entry rather than leaving a marker behind.
        let lock = KeyCombo(keyCode: kVK_ANSI_L, flags: [.control, .option, .command])
        settings.setHotKey(lock, for: .toggleLock)
        settings.setHotKey(nil, for: .toggleLock)
        #expect(settings.hotKeys["toggleLock"] == nil)
        #expect(AppSettings(defaults: defaults).hotKey(for: .toggleLock) == nil)

        // A stale empty entry from an older build reads as "not set".
        defaults.set(["toggleOverlay": [Int]()], forKey: "hotKeys")
        #expect(AppSettings(defaults: defaults).hotKey(for: .toggleOverlay) == nil)

        settings.clearHotKeys()
        #expect(settings.hotKey(for: .togglePause) == nil)
        #expect(settings.hotKeyBindings.isEmpty)
    }

    @Test func menuShortcutMirrorsWhatSwiftUICanSpell() {
        let lock = KeyCombo(keyCode: kVK_ANSI_L, flags: [.control, .option, .command])
        let shortcut = lock.keyboardShortcut
        #expect(shortcut?.modifiers == [.control, .option, .command])
        // The letter comes from the machine's ASCII layout (Dvorak prints "n" for key 37).
        let expected = KeyCombo.name(forKeyCode: UInt16(kVK_ANSI_L)).lowercased()
        #expect(expected.count == 1)
        #expect(shortcut.map { String($0.key.character) } == expected)
        #expect(KeyCombo(keyCode: kVK_Return, flags: [.command]).keyboardShortcut?.key == .return)
        #expect(KeyCombo(keyCode: kVK_F5, flags: []).keyboardShortcut == nil)
        #expect(KeyCombo(keyCode: kVK_ANSI_Keypad5, flags: [.command]).keyboardShortcut == nil)
    }

    @Test func fixedInWindowKeysAreRecognisedAsOwned() {
        let fixed: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_Return, [.command]), (kVK_ANSI_P, [.command, .shift]), (kVK_ANSI_Period, [.command]),
            (kVK_ANSI_H, [.command, .shift]), (kVK_ANSI_Comma, [.command]),
        ]
        for (code, flags) in fixed {
            let combo = KeyCombo(keyCode: code, flags: flags)
            #expect(combo.keyboardShortcut.map { mine in KeyCombo.fixedInWindow.contains { $0.shortcut == mine } } == true, "\(combo.display)")
        }
        let family: NSEvent.ModifierFlags = [.control, .option, .command]
        for combo in [KeyCombo(keyCode: kVK_ANSI_H, flags: family), KeyCombo(keyCode: kVK_Return, flags: family), KeyCombo(keyCode: kVK_F5, flags: [])] {
            #expect(combo.keyboardShortcut.map { mine in KeyCombo.fixedInWindow.contains { $0.shortcut == mine } } != true, "\(combo.display)")
        }
    }

    @Test func conflictsNameTheOtherActionAndIgnoreTheActionItself() {
        let (defaults, suite) = isolated()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let lock = KeyCombo(keyCode: kVK_ANSI_L, flags: [.control, .option, .command])
        settings.setHotKey(lock, for: .toggleLock)
        #expect(settings.hotKeyOwner(of: lock, excluding: .togglePause) == .toggleLock)
        #expect(settings.hotKeyOwner(of: lock, excluding: .toggleLock) == nil)
        #expect(settings.hotKeyOwner(of: KeyCombo(keyCode: kVK_F5, flags: []), excluding: .togglePause) == nil)
    }
}
