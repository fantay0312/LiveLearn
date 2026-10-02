import SwiftUI

/// One shortcut row, shared by 快捷键 and 语音输入. Its rag is three fixed slots (round 12) in the
/// order a reader and VoiceOver meet them — the binding, the 单键 menu, 清除 — so a row never
/// shifts when it gains or loses a binding and the rows of a group read as one table: the
/// binding right-aligned in `bindingSlot`, the menu in `modeSlot`, and `clearSlot` reserved at
/// the rag for 清除, which only a bound row fills.
///
/// A row that stands alone among other controls (语音输入's 按住说话) has no table to keep: it
/// passes `reservesClearSlot: false`, so unbound it ends on the rag like the menus above and
/// below it, and 清除 takes its slot only when there is something to clear.
struct ShortcutBindingControl: View {
    let action: HotKeyAction
    var reservesClearSlot = true
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var error: String?

    /// Wide enough for the longest combination the recorder prints (⌃⌥⇧⌘ plus a key name) and
    /// for "按键后松开" with its now bar.
    static let bindingSlot: CGFloat = 120
    /// "单键" at 11 pt with its chevron.
    static let modeSlot: CGFloat = 40
    /// 清除 at 13/500.
    static let clearSlot: CGFloat = 32
    static let slotGap = LLMetrics.space(4)

    var body: some View {
        let combo = model.settings.hotKey(for: action)
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(action == .holdDictation ? "按住说话" : action.title) {
                HStack(spacing: Self.slotGap) {
                    ShortcutRecorder(action: action, combo: combo, refused: HotKeyCenter.shared.unavailable.contains(action),
                                     width: Self.bindingSlot) { attempt in
                        assign(attempt)
                    }
                    // Quieter than the binding it offers an alternative to: 11 pt `ink3`.
                    PaperMenu(title: "单键", font: LLFont.label, color: theme.ink3, help: "直接选择 Fn、Option 等单键") {
                        [ModifierShortcut.fn, .option, .rightOption, .control, .rightControl, .shift, .rightShift, .command, .rightCommand].map { key in
                            .row(key.title, id: String(key.rawValue), selected: combo == KeyCombo(keyCode: key.rawValue, modifiers: 0)) {
                                _ = assign(KeyCombo(keyCode: key.rawValue, modifiers: 0))
                            }
                        }
                    }
                    .frame(width: Self.modeSlot, alignment: .trailing)
                    if reservesClearSlot || combo != nil {
                        ZStack(alignment: .trailing) {
                            if combo != nil {
                                Button("清除") { _ = assign(nil) }.buttonStyle(SettingsActionStyle())
                            }
                        }
                        .frame(width: Self.clearSlot, alignment: .trailing)
                    }
                }
            }
            if let error { SettingsNote(error, color: theme.brick) }
            if HotKeyCenter.shared.unavailable.contains(action) {
                SettingsNote(combo?.isModifierOnly == true ? "需要允许辅助功能权限，然后重新检查。" : "这个键已被系统或其他应用占用。", color: theme.brick)
                Button("重新检查") { HotKeyCenter.shared.apply(model.settings.hotKeyBindings) }.buttonStyle(SettingsActionStyle())
            }
        }
    }

    private func assign(_ attempt: KeyCombo?) -> Bool {
        if let attempt {
            guard attempt.isAcceptable else { error = "不支持这个键。"; return false }
            if attempt != model.settings.hotKey(for: action), let owner = attempt.ownChordTitle() {
                error = "该键已用于\(owner)。"; return false
            }
            if let owner = model.settings.hotKeyOwner(of: attempt, excluding: action) {
                error = "该键已用于「\(owner.title)」。"; return false
            }
        }
        model.settings.setHotKey(attempt, for: action)
        if action == .holdDictation { model.settings.dictation.holdWithFn = false }
        error = nil
        return true
    }
}
