import AppKit
import Carbon
import Testing
@testable import LiveLearnApp

@MainActor
struct SingleKeyShortcutTests {
    private func event(_ type: NSEvent.EventType, code: UInt16, flags: UInt = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .init(rawValue: flags), timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    @Test func optionIsRecordedOnlyAfterItsRelease() throws {
        var recording = ShortcutRecordingState()
        #expect(recording.consume(try event(.flagsChanged, code: 58, flags: NSEvent.ModifierFlags.option.rawValue | 0x20)) == nil)
        #expect(recording.consume(try event(.flagsChanged, code: 58)) == KeyCombo(keyCode: UInt16(58), modifiers: 0))
    }

    @Test func pressingLetterAfterOptionStillRecordsACombination() throws {
        var recording = ShortcutRecordingState()
        _ = recording.consume(try event(.flagsChanged, code: 58, flags: NSEvent.ModifierFlags.option.rawValue | 0x20))
        #expect(recording.consume(try event(.keyDown, code: 0, flags: NSEvent.ModifierFlags.option.rawValue | 0x20)) == KeyCombo(keyCode: 0, flags: [.option]))
        #expect(recording.consume(try event(.flagsChanged, code: 58)) == nil)
    }

    @Test func leftReleaseIsRecognizedWhileRightOptionRemainsDown() {
        let option = CGEventFlags.maskAlternate.rawValue
        #expect(ModifierShortcut.option.isDown(flags: option | 0x60))
        #expect(!ModifierShortcut.option.isDown(flags: option | 0x40))
        #expect(ModifierShortcut.rightOption.isDown(flags: option | 0x40))
        #expect(!ModifierShortcut.rightOption.isDown(flags: 0))
    }

    @Test func fnAndBothSidesOfModifiersRoundTripWithoutDuplicatedModifierFlags() {
        for key in ModifierShortcut.allCases {
            let combo = KeyCombo(keyCode: key.rawValue, modifiers: 0)
            #expect(combo.isAcceptable && combo.isModifierOnly)
            #expect(combo.display == key.title)
            #expect(combo.keyboardShortcut == nil)
            #expect(KeyCombo(stored: combo.stored) == combo)
        }
        #expect(!KeyCombo(keyCode: UInt16(57), modifiers: 0).isAcceptable)
    }

    @Test func bareSpaceAndLetterAreRecorded() throws {
        var recording = ShortcutRecordingState()
        #expect(recording.consume(try event(.keyDown, code: 49)) == KeyCombo(keyCode: 49, flags: []))
        #expect(recording.consume(try event(.keyDown, code: 9)) == KeyCombo(keyCode: 9, flags: []))
    }

    @Test func fnIsRecordedOnReleaseAndCanBeCancelled() throws {
        var recording = ShortcutRecordingState()
        #expect(recording.consume(try event(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue)) == nil)
        #expect(recording.consume(try event(.flagsChanged, code: 63)) == KeyCombo(keyCode: UInt16(63), modifiers: 0))
        _ = recording.consume(try event(.flagsChanged, code: 63, flags: NSEvent.ModifierFlags.function.rawValue))
        recording = ShortcutRecordingState()
        #expect(recording.consume(try event(.flagsChanged, code: 63)) == nil)
    }

    @Test func legacyFnSettingMigratesToTheSameRecorder() {
        let name = "LiveLearn.testing.singleKey.\(UUID())"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        store.set(true, forKey: "dictation.holdWithFn")
        let settings = AppSettings(defaults: store)
        #expect(!settings.dictation.holdWithFn)
        #expect(settings.hotKey(for: .holdDictation) == KeyCombo(keyCode: UInt16(63), modifiers: 0))
        #expect(AppSettings(defaults: store).hotKey(for: .holdDictation) == settings.hotKey(for: .holdDictation))
    }

    @Test func optimizedDefaultsAutofillEmptyFieldsAndPreserveOverrides() throws {
        let profile = try #require(OptimizedDictationDefaults.bundled)
        #expect(!profile.deviceID.isEmpty && !profile.appKey.isEmpty && !profile.tokenRequired)
        let name = "LiveLearn.testing.defaults.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("", forKey: "dictation.optimizedDeviceID")
        let initial = DictationSettings(defaults: defaults)
        #expect(initial.optimizedDeviceID == profile.deviceID && initial.optimizedURL == profile.url)
        initial.optimizedDeviceID = "12345"
        #expect(DictationSettings(defaults: defaults).optimizedDeviceID == "12345")
    }
}
