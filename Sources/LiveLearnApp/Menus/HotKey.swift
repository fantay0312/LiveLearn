import AppKit
import Carbon
import Observation
import SwiftUI

/// One key with its modifiers: what Carbon registers and what the settings page prints.
///
/// Modifiers are kept in Carbon's mask (`cmdKey` / `optionKey` / `controlKey` / `shiftKey`), the
/// form `RegisterEventHotKey` wants; conversions from `NSEvent` live here so nothing else has to
/// know the numbers. `display` prints the combination the way macOS does: ⌃ ⌥ ⇧ ⌘ in that order,
/// then the key as the current keyboard layout names it.
struct KeyCombo: Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: UInt32

    init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & KeyCombo.allModifiers
    }

    init(keyCode: Int, flags: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt16(keyCode), modifiers: KeyCombo.carbonModifiers(flags))
    }

    /// The combination a key-down event describes; nil for a bare modifier key.
    init?(event: NSEvent) {
        guard event.type == .keyDown, !KeyCombo.modifierKeyCodes.contains(event.keyCode) else { return nil }
        self.init(keyCode: Int(event.keyCode), flags: event.modifierFlags)
    }

    // MARK: Modifiers

    static let allModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    var flags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    /// ⌘, ⌃ or ⌥: the modifiers that make a global combination safe to take from other apps.
    var hasCommandingModifier: Bool { modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 }

    var isFunctionKey: Bool { KeyCombo.functionKeyNames[keyCode] != nil }

    var isModifierOnly: Bool { modifiers == 0 && ModifierShortcut(rawValue: keyCode) != nil }
    var isAcceptable: Bool { isModifierOnly || (keyCode < 128 && !Self.modifierKeyCodes.contains(keyCode)) }

    // MARK: Display

    var display: String { modifierGlyphs + KeyCombo.name(forKeyCode: keyCode) }

    var modifierGlyphs: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// The key alone: "S", "↩", "F5", "空格". Letters and symbols come from the current
    /// ASCII-capable keyboard layout, so a French or Dvorak layout prints its own key.
    static func name(forKeyCode code: UInt16) -> String {
        if let modifier = ModifierShortcut(rawValue: code) { return modifier.title }
        if let special = specialKeyNames[code] { return special }
        if let f = functionKeyNames[code] { return f }
        if let pad = keypadNames[code] { return pad }
        if let layout = layoutName(forKeyCode: code), !layout.isEmpty { return layout }
        return ansiFallback[code] ?? "键 \(code)"
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "空格", 51: "⌫", 117: "⌦", 53: "⎋", 71: "⌧",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    private static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let keypadNames: [UInt16: String] = [
        65: "小键盘 .", 67: "小键盘 *", 69: "小键盘 +", 75: "小键盘 /", 78: "小键盘 -", 81: "小键盘 =",
        82: "小键盘 0", 83: "小键盘 1", 84: "小键盘 2", 85: "小键盘 3", 86: "小键盘 4", 87: "小键盘 5",
        88: "小键盘 6", 89: "小键盘 7", 91: "小键盘 8", 92: "小键盘 9",
    ]

    /// US layout, used only when the layout lookup fails.
    private static let ansiFallback: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// Asks the current ASCII-capable layout what the key prints with no modifiers held.
    fileprivate static func layoutName(forKeyCode code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).uppercased()
            // Control characters (tab, return) are named in the table above; anything unprintable
            // falls through to the ANSI table.
            return s.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) ? s : nil
        }
    }

    // MARK: Persistence

    /// `[keyCode, modifiers]`, the form kept in UserDefaults.
    var stored: [Int] { [Int(keyCode), Int(modifiers)] }

    init?(stored: [Int]) {
        guard stored.count == 2,
              let keyCode = UInt16(exactly: stored[0]),
              let modifiers = UInt32(exactly: stored[1]) else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers)
    }
}

/// What a global shortcut can do. The raw values are stored, so they never change.
enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case toggleSession, togglePause, toggleOverlay, toggleLock, showMainWindow
    case toggleDictation, cancelDictation
    case holdDictation

    var id: String { rawValue }

    /// The id Carbon hands back when the key is pressed.
    var carbonID: UInt32 { UInt32(HotKeyAction.allCases.firstIndex(of: self)! + 1) }

    var title: String {
        switch self {
        case .toggleSession: return "开始 / 停止会话"
        case .togglePause: return "暂停 / 继续"
        case .toggleOverlay: return "显示 / 隐藏字幕"
        case .toggleLock: return "锁定 / 解锁浮层"
        case .showMainWindow: return "打开主窗口"
        case .toggleDictation: return "开始 / 完成语音输入"
        case .cancelDictation: return "取消语音输入"
        case .holdDictation: return "按住说话（自定义）"
        }
    }

    var note: String {
        switch self {
        case .toggleSession: return "未开始时按下就开始实时翻译，进行中按下就停止。不能开始时会打开主窗口说明原因。"
        case .togglePause: return "会话进行中暂停或继续；暂停时音频不送入引擎。"
        case .toggleOverlay: return "显示或隐藏字幕；隐藏时按「字幕外观」中的关闭行为设置处理会话。"
        case .toggleLock: return "锁定后浮层点击穿透，鼠标可以直接操作它下面的内容；设了这个键就能不经菜单栏直接解锁。"
        case .showMainWindow: return "把主窗口带到最前面，关掉主窗口后也能用。"
        case .toggleDictation: return "在当前输入框中开始听写，再按一次完成；不会切换输入法或激活主窗口。"
        case .cancelDictation: return "立即停止录音和后续纠错，保留已经写入的文字。"
        case .holdDictation: return "按住设置的单键或组合键说话，松开后完成。"
        }
    }

    // Nothing ships bound. Every global chord is taken from every other app while LiveLearn
    // runs, so each one is the user's own choice (§9.4); the menu bar panel and the 会话 menu
    // already reach all five actions without a key.
}

extension KeyCombo {
    /// The same combination as a SwiftUI menu shortcut, for the 会话 menu to show beside the
    /// action. nil for keys SwiftUI cannot spell (function keys, the keypad); the menu item
    /// then simply carries no key. Carbon consumes the keystroke system-wide, so a shared
    /// combination never fires both handlers.
    var keyboardShortcut: KeyboardShortcut? {
        guard !isModifierOnly else { return nil }
        var mods: SwiftUI.EventModifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        let key: KeyEquivalent
        switch Int(keyCode) {
        case kVK_Return: key = .return
        case kVK_Tab: key = .tab
        case kVK_Space: key = .space
        case kVK_Delete: key = .delete
        case kVK_ForwardDelete: key = .deleteForward
        case kVK_Escape: key = .escape
        case kVK_LeftArrow: key = .leftArrow
        case kVK_RightArrow: key = .rightArrow
        case kVK_UpArrow: key = .upArrow
        case kVK_DownArrow: key = .downArrow
        case kVK_Home: key = .home
        case kVK_End: key = .end
        case kVK_PageUp: key = .pageUp
        case kVK_PageDown: key = .pageDown
        default:
            guard !isFunctionKey, KeyCombo.keypadCodes.contains(keyCode) == false,
                  let name = KeyCombo.layoutCharacter(forKeyCode: keyCode), name.count == 1,
                  let scalar = name.unicodeScalars.first else { return nil }
            key = KeyEquivalent(Character(scalar))
        }
        return KeyboardShortcut(key, modifiers: mods)
    }

    private static let keypadCodes: Set<UInt16> = [65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// The lowercase character the key prints, for a key equivalent.
    fileprivate static func layoutCharacter(forKeyCode code: UInt16) -> String? {
        layoutName(forKeyCode: code)?.lowercased()
    }

    // MARK: Chords the app already owns

    /// The fixed in-window keys (设置 › 快捷键 › 主窗口内). A global combination may never take one:
    /// Carbon would consume the chord system-wide and the in-window item would go dead.
    static let fixedInWindow: [(shortcut: KeyboardShortcut, title: String)] = [
        (KeyboardShortcut(.return, modifiers: .command), "开始"),
        (KeyboardShortcut("p", modifiers: [.command, .shift]), "暂停 / 继续"),
        (KeyboardShortcut(".", modifiers: .command), "停止"),
        (KeyboardShortcut("h", modifiers: [.command, .shift]), "显示 / 隐藏字幕"),
        (KeyboardShortcut(",", modifiers: .command), "设置"),
    ]

    /// What this combination already does inside the app, if anything: a fixed in-window key,
    /// or a main-menu item's key equivalent (⌘Q, ⌘W, ⌘H, the Edit menu…). Nil when it is free.
    @MainActor
    func ownChordTitle() -> String? {
        if let mine = keyboardShortcut, let fixed = KeyCombo.fixedInWindow.first(where: { $0.shortcut == mine }) {
            return "主窗口内「\(fixed.title)」"
        }
        if let mine = keyboardShortcut {
            for digit in 0...9 where mine == KeyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command) {
                return "设置页面切换「⌘\(digit)」"
            }
        }
        if let item = conflictingMenuItem(in: NSApp.mainMenu) {
            return "菜单「\(item.title)」"
        }
        return nil
    }

    /// The AppKit key-equivalent string this key prints, for comparing with `NSMenuItem`.
    private var keyEquivalentString: String? {
        switch Int(keyCode) {
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Space: return " "
        case kVK_Escape: return "\u{1B}"
        case kVK_Delete: return "\u{08}"
        case kVK_ForwardDelete: return String(UnicodeScalar(NSDeleteFunctionKey)!)
        case kVK_LeftArrow: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case kVK_RightArrow: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case kVK_UpArrow: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case kVK_DownArrow: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default: return KeyCombo.layoutCharacter(forKeyCode: keyCode)
        }
    }

    /// The menu item whose key equivalent is this combination, walking submenus. An uppercase
    /// letter equivalent means ⇧ (AppKit's convention); only ⌘⌥⌃⇧ are compared.
    @MainActor
    private func conflictingMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu, let key = keyEquivalentString else { return nil }
        let wanted = flags.intersection([.command, .option, .control, .shift])
        for item in menu.items {
            if let sub = item.submenu, let hit = conflictingMenuItem(in: sub) { return hit }
            guard !item.keyEquivalent.isEmpty else { continue }
            var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
            var equivalent = item.keyEquivalent
            if equivalent.count == 1, equivalent != equivalent.lowercased() {
                mask.insert(.shift)
                equivalent = equivalent.lowercased()
            }
            if equivalent == key, mask == wanted { return item }
        }
        return nil
    }
}

/// Global hotkeys via Carbon `RegisterEventHotKey`: system-wide, no Accessibility permission.
///
/// `apply` is given the whole binding table and registers only what changed. While a shortcut
/// is being recorded the table is suspended, so pressing the current combination records it
/// instead of firing it. `unavailable` lists the actions whose combination the system refused;
/// the settings page reads it.
@MainActor
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private(set) var unavailable: Set<HotKeyAction> = []
    /// Bumped when the keyboard layout changes, so rows that print a combination re-read it.
    private(set) var layoutVersion = 0
    @ObservationIgnored var handler: (@MainActor (HotKeyAction) -> Void)?
    @ObservationIgnored var releaseHandler: (@MainActor (HotKeyAction) -> Void)?
    @ObservationIgnored var cancellationHandler: (@MainActor (HotKeyAction) -> Void)?
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var registered: [HotKeyAction: (combo: KeyCombo, ref: EventHotKeyRef)] = [:]
    @ObservationIgnored private var wanted: [HotKeyAction: KeyCombo] = [:]
    @ObservationIgnored private var heldActions: Set<HotKeyAction> = []
    @ObservationIgnored private var modifierMonitors: [HotKeyAction: ModifierKeyMonitor] = [:]
    @ObservationIgnored private(set) var suspended = false
    @ObservationIgnored private var layoutObserver: NSObjectProtocol?

    private init() {
        layoutObserver = NotificationCenter.default.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.layoutVersion += 1 }
        }
    }

    func apply(_ bindings: [HotKeyAction: KeyCombo]) {
        wanted = bindings
        if !suspended { reconcile() }
    }

    /// Lets every key through while a shortcut is being recorded.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        unregisterAll(keepWanted: true)
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        reconcile()
    }

    func unregisterAll() {
        unregisterAll(keepWanted: false)
        if let h = handlerRef { RemoveEventHandler(h) }
        handlerRef = nil
    }

    private func unregisterAll(keepWanted: Bool) {
        for action in heldActions { releaseHeld(action) }
        for monitor in modifierMonitors.values { monitor.stop() }
        modifierMonitors = [:]
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        if !keepWanted { wanted = [:] }
    }

    private func reconcile() {
        installHandlerIfNeeded()
        for (action, monitor) in modifierMonitors where wanted[action]?.keyCode != monitor.key.rawValue || wanted[action]?.isModifierOnly != true {
            releaseHeld(action); monitor.stop(); modifierMonitors[action] = nil
        }
        // Drop what is gone or changed.
        for (action, entry) in registered where wanted[action] != entry.combo {
            releaseHeld(action)
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        var failed: Set<HotKeyAction> = []
        for action in HotKeyAction.allCases {
            guard let combo = wanted[action], registered[action] == nil else { continue }
            if combo.isModifierOnly, let key = ModifierShortcut(rawValue: combo.keyCode) {
                let monitor: ModifierKeyMonitor
                if let existing = modifierMonitors[action] { monitor = existing }
                else {
                    monitor = ModifierKeyMonitor(key: key, fireOnPress: action == .holdDictation)
                    monitor.onPress = { [weak self] in self?.fire(id: action.carbonID, released: false) }
                    monitor.onRelease = { [weak self] in self?.fire(id: action.carbonID, released: true) }
                    monitor.onCancel = { [weak self] in self?.cancelHeld(action) }
                    modifierMonitors[action] = monitor
                }
                monitor.setEnabled(true)
                if monitor.unavailable { failed.insert(action) }
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x4C4C726E /* 'LLrn' */, id: action.carbonID)
            // Exclusive: a combination another app already holds is refused (eventHotKeyExistsErr)
            // instead of silently shared, so the settings page can say so.
            let status = RegisterEventHotKey(UInt32(combo.keyCode), combo.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                registered[action] = (combo, ref)
            } else {
                failed.insert(action)
            }
        }
        if failed != unavailable { unavailable = failed }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = id.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            Task { @MainActor in HotKeyCenter.shared.fire(id: pressed, released: released) }
            return noErr
        }, 2, &eventTypes, nil, &handlerRef)
    }

    private func fire(id: UInt32, released: Bool) {
        guard !suspended, let action = HotKeyAction.allCases.first(where: { $0.carbonID == id }) else { return }
        if action == .holdDictation {
            if released { releaseHeld(action) }
            else if heldActions.insert(action).inserted { handler?(action) }
        } else if !released { handler?(action) }
    }

    private func releaseHeld(_ action: HotKeyAction) {
        if heldActions.remove(action) != nil { releaseHandler?(action) }
    }

    private func cancelHeld(_ action: HotKeyAction) {
        guard heldActions.remove(action) != nil else { return }
        if let cancellationHandler { cancellationHandler(action) } else { releaseHandler?(action) }
    }

    func resetDictationModifier() {
        guard let monitor = modifierMonitors[.holdDictation] else { return }
        heldActions.remove(.holdDictation)
        monitor.reset()
    }

    #if DEBUG
    func dispatchForVerification(_ action: HotKeyAction, released: Bool = false) { fire(id: action.carbonID, released: released) }
    #endif
}
