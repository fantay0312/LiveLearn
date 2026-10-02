import AppKit
@preconcurrency import ApplicationServices
import Carbon
import EngineKit

enum DictationInputError: Error, CustomStringConvertible {
    case permission, secure, unsupported, changed, unconfirmed, hostFocused
    var description: String {
        switch self {
        case .permission: "需要在系统设置的「辅助功能」中允许 LiveLearn，才能写入其他应用。"
        case .secure: "安全输入或密码框中不启动语音输入。"
        case .unsupported: "请先点选要输入的文字框，再开始语音输入。"
        case .changed: "输入位置或文字已改变，已停止自动写入；结果保留在预览中。"
        case .unconfirmed: "无法确认输入框是否接受修改，已停止自动写入，避免重复输入。"
        case .hostFocused: "完成后会回到原输入框。"
        }
    }
}

struct DictationInputSnapshot: Equatable {
    let text: String?
    let selection: NSRange?
    let selectedText: String?

    var insertion: DictationInsertion? {
        guard let text, let selection else { return nil }
        return DictationInsertion(text: text, selection: selection)
    }

    func accepts(_ current: Self) -> Bool {
        (text == nil || current.text == text) &&
        (selection == nil || current.selection == selection) &&
        (selectedText == nil || current.selectedText == selectedText)
    }
}

@MainActor
protocol DictationTextTarget: AnyObject {
    var appName: String { get }
    var anchorRect: CGRect? { get }
    var supportsLiveInsertion: Bool { get }
    var canConfirmDelivery: Bool { get }
    func replace(with text: String) throws
    func restoreOriginalSelection() throws
    func commit(_ text: String) async throws
}

extension DictationTextTarget {
    var anchorRect: CGRect? { nil }
    var supportsLiveInsertion: Bool { true }
    var canConfirmDelivery: Bool { true }
    func commit(_ text: String) async throws { try replace(with: text) }
}

@MainActor
final class DictationInputTarget: DictationTextTarget {
    let appName: String
    private let element: AXUIElement
    private let pid: pid_t
    private var insertion: DictationInsertion?
    private let initialSnapshot: DictationInputSnapshot
    private let allowsCompatiblePaste: Bool
    private(set) var supportsLiveInsertion: Bool
    var canConfirmDelivery: Bool { insertion != nil }

    var anchorRect: CGRect? {
        var selection = CFRange(location: insertion?.expectedSelection.location ?? initialSnapshot.selection?.location ?? 0, length: 0)
        if insertion != nil || initialSnapshot.selection != nil, let range = AXValueCreate(.cfRange, &selection) {
            var raw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &raw) == .success,
               let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                var rect = CGRect.zero
                if AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 0 { return Self.screenRect(rect) }
            }
        }
        guard let rawPosition = Self.attribute(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = Self.attribute(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return Self.screenRect(CGRect(origin: point, size: size))
    }

    private static func screenRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - rect.maxY, width: rect.width, height: rect.height)
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func capture(allowCompatiblePaste: Bool = false) throws -> DictationInputTarget {
        guard !IsSecureEventInputEnabled() else { throw DictationInputError.secure }
        guard accessibilityGranted else { throw DictationInputError.permission }
        let system = AXUIElementCreateSystemWide()
        guard let focused = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw DictationInputError.unsupported
        }
        let element = focused as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { throw DictationInputError.unsupported }
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { throw DictationInputError.secure }
        let snapshot = snapshot(element)
        guard (snapshot.text?.utf16.count ?? 0) <= 1_000_000 else { throw DictationInputError.unsupported }
        let live = snapshot.insertion != nil && settable(element, kAXSelectedTextRangeAttribute) &&
            (settable(element, kAXSelectedTextAttribute) || settable(element, kAXValueAttribute))
        let role = attribute(element, kAXRoleAttribute) as? String
        let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") ||
            attribute(element, "AXEditable") as? Bool == true
        guard attribute(element, kAXEnabledAttribute) as? Bool != false,
              live || (allowCompatiblePaste && editable) else {
            throw DictationInputError.unsupported
        }
        return DictationInputTarget(element: element, pid: pid, snapshot: snapshot, live: live, allowsCompatiblePaste: allowCompatiblePaste)
    }

    private init(element: AXUIElement, pid: pid_t, snapshot: DictationInputSnapshot, live: Bool, allowsCompatiblePaste: Bool) {
        self.element = element; self.pid = pid; initialSnapshot = snapshot; insertion = snapshot.insertion
        self.allowsCompatiblePaste = allowsCompatiblePaste
        supportsLiveInsertion = live
        appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "当前应用"
        AXUIElementSetMessagingTimeout(element, 0.3)
    }

    func replace(with text: String) throws {
        guard supportsLiveInsertion, let insertion else { throw DictationInputError.unsupported }
        try validate()
        guard insertion.inserted != text else { return }
        var next = insertion; next.replace(with: text)
        if Self.settable(element, kAXSelectedTextAttribute) {
            try setSelection(insertion.replacementRange)
            let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
            if try usePasteAfterRejectedWrite(result, insertion: insertion) { return }
        } else {
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, next.expectedText as CFString)
            if try usePasteAfterRejectedWrite(result, insertion: insertion) { return }
        }
        guard Self.attribute(element, kAXValueAttribute) as? String == next.expectedText else { throw DictationInputError.unconfirmed }
        try setSelection(next.expectedSelection)
        guard Self.selectedRange(element) == next.expectedSelection else { throw DictationInputError.unconfirmed }
        self.insertion = next
    }

    private func usePasteAfterRejectedWrite(_ result: AXError, insertion: DictationInsertion) throws -> Bool {
        guard result != .success else { return false }
        guard allowsCompatiblePaste, insertion.inserted == nil, result == .attributeUnsupported || result == .notImplemented,
              Self.attribute(element, kAXValueAttribute) as? String == insertion.expectedText else {
            throw DictationInputError.unconfirmed
        }
        try setSelection(insertion.expectedSelection)
        try validate()
        supportsLiveInsertion = false
        return true
    }

    private func validate() throws {
        guard !IsSecureEventInputEnabled() else { throw DictationInputError.secure }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            throw DictationInputError.hostFocused
        }
        guard let current = Self.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFEqual(current, element), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw DictationInputError.changed
        }
        let currentSnapshot = Self.snapshot(element)
        if let insertion {
            guard currentSnapshot.text == insertion.expectedText, currentSnapshot.selection == insertion.expectedSelection else { throw DictationInputError.changed }
        } else if !initialSnapshot.accepts(currentSnapshot) { throw DictationInputError.changed }
    }

    func commit(_ text: String) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            guard let app = NSRunningApplication(processIdentifier: pid), app.activate(options: []) else { throw DictationInputError.changed }
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            }
        }
        try validate()
        if !allowsCompatiblePaste { try replace(with: text); return }
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general, lease = DictationInputSourceLease()
        let snapshot = DictationPasteboardSnapshot(pasteboard)
        try lease.selectASCIIIfNeeded()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let change = pasteboard.changeCount
        defer { snapshot.restore(pasteboard, ifUnchanged: change); lease.restore() }
        try await Task.sleep(for: .milliseconds(40))
        try Task.checkCancellation()
        try validate()
        guard pasteboard.changeCount == change else { throw DictationInputError.changed }
        if let insertion, insertion.inserted != nil {
            try setSelection(insertion.replacementRange)
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { throw DictationInputError.unconfirmed }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        var next = insertion; next?.replace(with: text)
        for _ in 0..<40 {
            // Once Cmd+V has been posted, keep its clipboard alive until the target has read
            // it (or the bounded observation ends), even if the user cancels meanwhile.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
            if let next, let value = Self.attribute(element, kAXValueAttribute) as? String,
               let selection = Self.selectedRange(element), next.accepts(text: value, selection: selection) {
                insertion = next
                return
            }
        }
        // Some editors expose neither a complete value nor a selection range. Cmd+V
        // is sent once to the captured process; never retry an unobservable paste.
        if next == nil { return }
        throw DictationInputError.unconfirmed
    }

    func restoreOriginalSelection() throws {
        guard let insertion, insertion.inserted != nil else { return }
        let original = insertion.original, range = insertion.range
        try replace(with: (original as NSString).substring(with: range))
        try setSelection(range)
        guard Self.selectedRange(element) == range else { throw DictationInputError.unconfirmed }
        self.insertion = DictationInsertion(text: original, selection: range)!
    }

    private func setSelection(_ range: NSRange) throws {
        var value = CFRange(location: range.location, length: range.length)
        guard let wrapped = AXValueCreate(.cfRange, &value),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, wrapped) == .success else {
            throw DictationInputError.unconfirmed
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
    }
    private static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
    private static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func snapshot(_ element: AXUIElement) -> DictationInputSnapshot {
        DictationInputSnapshot(text: attribute(element, kAXValueAttribute) as? String,
            selection: selectedRange(element), selectedText: attribute(element, kAXSelectedTextAttribute) as? String)
    }
}
