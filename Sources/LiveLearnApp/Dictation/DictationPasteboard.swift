import AppKit
@preconcurrency import Carbon

struct DictationPasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    @MainActor init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    @MainActor func restore(_ pasteboard: NSPasteboard, ifUnchanged changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        let restored = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

@MainActor
final class DictationInputSourceLease {
    private var original: TISInputSource?
    private var temporaryID: String?

    func selectASCIIIfNeeded() throws {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let type = Self.string(source, kTISPropertyInputSourceType), type == kTISTypeKeyboardInputMode as String || type == kTISTypeKeyboardInputMethodWithoutModes as String else { return }
        guard let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue(),
              TISSelectInputSource(ascii) == noErr else { throw DictationInputError.unconfirmed }
        original = source
        temporaryID = Self.string(ascii, kTISPropertyInputSourceID)
    }

    func restore() {
        guard let original, let temporaryID, let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              Self.string(current, kTISPropertyInputSourceID) == temporaryID else { return }
        TISSelectInputSource(original)
        self.original = nil
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
