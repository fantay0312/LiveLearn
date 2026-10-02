import SwiftUI
import AppKit

/// 设置 › 快捷键 (§9.4): the global shortcuts, one row per action, each with a recorder at the
/// right; then the fixed in-window shortcuts as facts, so both kinds are on one page.
///
/// Recording is a state of the row, not a sheet: press the control, press the keys. Nothing on
/// the page is filled or boxed; the only accent is the now bar that says a row is listening
/// right now (`ShortcutRecorder`).
struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let center = HotKeyCenter.shared
        // Read so a keyboard layout change re-prints every combination on the page.
        let _ = center.layoutVersion
        SettingsPage(title: "快捷键", note: "点击录制；⌫ 清除，Esc 取消。") {
            SettingsGroup("按住说话", note: "支持 Fn、左右 Option / Control / Shift / Command、普通单键和组合键。修饰键按下后松开即可录入。") {
                ShortcutBindingControl(action: .holdDictation)
            }
            SettingsGroup("全局", help: "单键或组合键均可设置。独立修饰键需要辅助功能权限；普通单键会成为全局快捷键，不再用于正常输入。") {
                ForEach(Array(HotKeyAction.allCases.filter { $0 != .holdDictation }.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { SheetDivider() }
                    ShortcutBindingControl(action: action)
                }
            }
            SettingsGroup("主窗口内（固定）", help: "仅在 LiveLearn 位于前台时生效。") {
                SettingRow("开始") { SettingValue("⌘↩") }
                SheetDivider()
                SettingRow("暂停 / 继续") { SettingValue("⌘⇧P") }
                SheetDivider()
                SettingRow("停止") { SettingValue("⌘.") }
                SheetDivider()
                SettingRow("显示 / 隐藏字幕") { SettingValue("⌘⇧H") }
                SheetDivider()
                SettingRow("设置") { SettingValue("⌘,") }
            }
        }
    }


}

/// The control that shows a combination and, when pressed, listens for the next one.
///
/// Bare text on the ground in every state (round 12: the graphite chip it rested on was the
/// last filled slab on the page), right-aligned in the row's binding slot (`width`), which is
/// also its whole target — so a click anywhere in the slot is a click on the control, never
/// "outside" it. The slot is 28 pt tall but, like a settings action, only its text line counts
/// in layout, so a shortcut row is as tall as any other one-line row, bound or not. Resting
/// with a combination: the glyphs in `ink`, tracked 1 pt so ⌃⌥⌘ read as
/// separate keys. Empty: "设置快捷键" in `ink2`, lifting under the pointer. Listening: the 2 pt
/// now bar — the app's one mark for "this moment" — before "按键后松开". Esc cancels, ⌫ clears,
/// a click anywhere else cancels, and the app losing focus cancels. Global registration is
/// suspended while listening so the current combination can be pressed to re-record it.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    let combo: KeyCombo?
    var refused = false
    /// The slot the text is right-aligned in; `nil` hugs the text.
    var width: CGFloat? = nil
    /// Returns true when the attempt was accepted (recording ends), false to keep listening.
    let onRecord: (KeyCombo?) -> Bool
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recording = false
    @State private var hovering = false
    @State private var monitor: Any?
    @State private var deactivation: Any?
    @State private var anchor = RecorderAnchor()
    @State private var keyRecording = ShortcutRecordingState()

    var body: some View {
        if staticRender {
            Text(combo?.display ?? "未设置")
                .font(LLFont.body)
                .tracking(combo == nil ? 0 : 1)
                .foregroundStyle(combo == nil ? theme.ink3 : theme.ink)
                .frame(width: width, alignment: .trailing)
                .frame(height: LLMetrics.controlHeight)
                .padding(.vertical, -SettingsActionStyle.targetOverhang)
        } else {
            Button {
                if recording { end() } else { begin() }
            } label: {
                HStack(spacing: LLMetrics.space(2)) {
                    if recording {
                        NowMark().frame(height: 14)
                            .transition(.opacity)
                    }
                    Text(label)
                        .font(LLFont.body)
                        .tracking(combo != nil && !recording ? 1 : 0)
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .trailing)
                .frame(height: LLMetrics.controlHeight)
                // The slot is the target, and the anchor the click-outside test reads is this
                // same frame, so the two can never disagree.
                .contentShape(Rectangle())
            }
            .buttonStyle(InlineButtonStyle())
            .background(RecorderAnchorView(anchor: anchor))
            .onHover { hovering = $0 }
            .animation(LLMotion.hover(reduceMotion), value: hovering)
            .animation(LLMotion.hover(reduceMotion), value: recording)
            .onDisappear { end() }
            .help(recording ? "按下单键或组合键，修饰键松开录入；⌫ 清除，Esc 取消" : "点击后按下单键或组合键")
            .accessibilityLabel("\(action.title)快捷键")
            .accessibilityValue(recording ? "正在录制" : (combo?.display ?? "未设置"))
            .accessibilityHint("按下单键或组合键设置；修饰键松开录入；⌫ 清除，Esc 取消")
            .padding(.vertical, -SettingsActionStyle.targetOverhang)
        }
    }

    private var label: String {
        if recording { return "按键后松开" }
        return combo?.display ?? "设置快捷键"
    }

    private var color: Color {
        if recording { return theme.ink2 }
        if combo == nil { return hovering ? theme.ink : theme.ink2 }
        return refused ? theme.ochre : theme.ink
    }

    private func begin() {
        guard !recording else { return }
        recording = true
        keyRecording = ShortcutRecordingState()
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in
            switch event.type {
            case .keyDown, .flagsChanged:
                return handle(event)
            default:
                // A press on the control itself reaches the button, which ends the recording;
                // a press anywhere else ends it here and goes on to what it hit.
                if let view = anchor.view, let window = view.window, event.window === window,
                   view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    return event
                }
                end()
                return event
            }
        })
        deactivation = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { end() }
        }
    }

    private func end() {
        guard recording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let deactivation { NotificationCenter.default.removeObserver(deactivation) }
        deactivation = nil
        recording = false
        HotKeyCenter.shared.resume()
    }

    /// Esc cancels, ⌫ clears, anything else is an attempt; the key never reaches the window.
    private func handle(_ event: NSEvent) -> NSEvent? {
        let plain = KeyCombo.carbonModifiers(event.modifierFlags) == 0
        if event.keyCode == 53, plain {
            end()
            return nil
        }
        if event.keyCode == 51, plain {
            if onRecord(nil) { end() }
            return nil
        }
        guard let attempt = keyRecording.consume(event) else { return nil }
        if onRecord(attempt) { end() }
        return nil
    }
}

/// Where the recorder is on screen, so a click on it is told apart from a click elsewhere.
final class RecorderAnchor {
    weak var view: NSView?
}

private struct RecorderAnchorView: NSViewRepresentable {
    let anchor: RecorderAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
