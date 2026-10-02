import SwiftUI
import AppKit

/// 设置 › 语音输入. Round 12: the page follows the settings row grammar throughout — rules
/// between the rows of 开始使用 and inside every fold, the folds as one group, actions as words
/// (`SettingsActionStyle`), typed fields in the two widths, the replacement rules in a field
/// drawn like `QuietField`.
struct DictationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var accessibilityGranted = DictationInputTarget.accessibilityGranted
    @State private var connectionExpanded = false
    @State private var inputExpanded = false
    @State private var vocabularyExpanded = false
    @State private var chatterflyNeedsToken = true

    var body: some View {
        @Bindable var s = model.settings.dictation
        SettingsPage(title: "语音输入") {
            SettingsGroup("开始使用") {
                SettingRow("识别引擎") {
                    PaperMenu(title: s.engineLabel, font: LLFont.body, color: theme.ink, help: "选择语音识别引擎") {
                        RecognizerChoice.allCases.map { choice in
                            .row(choice.label, id: choice.rawValue, selected: s.engine == choice.rawValue) { s.engine = choice.rawValue }
                        } + [.row("豆包输入法引擎", id: DictationSettings.optimizedEngine,
                                  selected: s.engine == DictationSettings.optimizedEngine) { s.engine = DictationSettings.optimizedEngine },
                             .row("Chatterfly", id: DictationSettings.chatterflyEngine, selected: s.engine == DictationSettings.chatterflyEngine) { s.engine = DictationSettings.chatterflyEngine }]
                    }.disabled(model.dictation.isActive)
                }
                SheetDivider()
                SettingRow("语言") {
                    PaperMenu(title: s.languageLabel, font: LLFont.body, color: theme.ink, help: "识别语言") {
                        DictationLanguage.allCases.map { language in
                            .row(language.title, id: language.rawValue,
                                 selected: language.rawValue == s.language || (language == .simplified && s.language == "zh-Hans") || (language == .traditional && s.language == "zh-Hant")) {
                                s.language = language.rawValue
                            }
                        }
                    }.disabled(model.dictation.isActive)
                }
                SheetDivider()
                ShortcutBindingControl(action: .holdDictation, reservesClearSlot: false)
                SheetDivider()
                HStack(alignment: .firstTextBaseline, spacing: LLMetrics.space(5)) {
                    Button(model.dictation.phase == .listening ? "完成听写" : "开始语音输入") {
                        if model.dictation.phase == .listening { model.dictation.finish() }
                        else { model.dictation.startFromInterface() }
                    }
                    .buttonStyle(SettingsActionStyle())
                    .disabled(model.dictation.isActive && model.dictation.phase != .listening)
                    .help("回到要输入的应用，结束听写后自动输入")
                    if model.dictation.isActive {
                        Button("取消") { model.dictation.cancel() }.buttonStyle(SettingsActionStyle())
                    } else if !accessibilityGranted {
                        Button("允许输入权限…") {
                            DictationInputTarget.requestAccessibility()
                            accessibilityGranted = DictationInputTarget.accessibilityGranted
                        }.buttonStyle(SettingsActionStyle())
                    }
                    Spacer()
                    Text(destination).font(LLFont.label).foregroundStyle(theme.ink3)
                }
                // A row's own padding, so the action row is as tall as the rows above it.
                .padding(.vertical, LLMetrics.space(3))
                // What the last dictation reports is never a quiet `ink3` hint: a failure (no
                // input permission, a blocked start) in brick like every settings error, a
                // progress note ("已复制", "未识别到语音") in `ink2`.
                if let notice = model.dictation.notice {
                    SettingsNote(notice, color: model.dictation.phase == .failed ? theme.brick : theme.ink2)
                }
            }

            DictationRefinementSettings()

            SettingsGroup {
                DictationFold(title: "输入与浮窗", summary: s.liveInsertion ? "实时上屏" : "完成后输入", expanded: $inputExpanded) {
                    SettingsSheet {
                    SettingRow("输入方式") {
                        PaperMenu(title: s.liveInsertion ? "边说边输入" : "完成后输入", font: LLFont.body, color: theme.ink, help: "文字何时写入输入框") {
                            [.row("边说边输入", id: "live", selected: s.liveInsertion) { s.liveInsertion = true },
                             .row("完成后输入", id: "final", selected: !s.liveInsertion) { s.liveInsertion = false }]
                        }
                    }
                    SheetDivider()
                    SettingRow("浮窗位置") {
                        PaperMenu(title: s.nearInput ? "输入框旁" : "屏幕底部", font: LLFont.body, color: theme.ink, help: "听写浮窗的位置") {
                            [.row("输入框旁", id: "input", selected: s.nearInput) { s.nearInput = true },
                             .row("屏幕底部", id: "bottom", selected: !s.nearInput) { s.nearInput = false }]
                        }
                    }
                    SheetDivider()
                    SettingRow("兼容粘贴", note: "无法直接写入时，在完成后粘贴，并恢复输入法及剪贴板。") {
                        Toggle("兼容粘贴", isOn: $s.compatiblePaste).labelsHidden().toggleStyle(QuietSwitchStyle())
                    }
                    }
                }
                SheetDivider()
                DictationFold(title: "词汇替换", summary: s.rules.isEmpty ? "未设置" : "\(s.rules.count) 条", expanded: $vocabularyExpanded) {
                    // A typed field, so `QuietField`'s paper: `surface`, a 1 pt hairline, 6 pt round.
                    TextEditor(text: $s.replacements).font(LLFont.body)
                        .scrollContentBackground(.hidden).padding(10).frame(height: 108)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
                        .accessibilityLabel("听写替换规则")
                    SettingsNote("每行一条，例如：配森=Python")
                    Button("打开词汇库") { model.requestVocabularyWindow() }.buttonStyle(SettingsActionStyle())
                }
                SheetDivider()
                if s.engine == DictationSettings.optimizedEngine {
                    DictationFold(title: "引擎连接", summary: "已填入参数", expanded: $connectionExpanded) {
                        OptimizedEngineSettingsView()
                    }
                } else if s.engine == DictationSettings.chatterflyEngine {
                    DictationFold(title: "引擎连接", summary: chatterflyNeedsToken ? "需要授权 Token" : "已保存 Token", expanded: $connectionExpanded) {
                        CredentialRow(id: "dictation.chatterfly.token", title: "授权 Token", note: nil)
                        SettingsNote("Chatterfly 服务需要有效的授权 Token。")
                    }
                } else {
                    Button("配置识别服务…") { model.settings.requestedSettingsTab = .engine }
                        .buttonStyle(SettingsActionStyle()).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
            }.disabled(model.dictation.isActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = DictationInputTarget.accessibilityGranted
            HotKeyCenter.shared.apply(model.settings.hotKeyBindings)
        }
        .task(id: s.engine + String(model.settings.credentialsVersion)) {
            guard s.engine == DictationSettings.chatterflyEngine else { return }
            chatterflyNeedsToken = CredentialStore.load("dictation.chatterfly.token") == nil
            if chatterflyNeedsToken { connectionExpanded = true }
        }
    }

    private var destination: String {
        if model.settings.dictation.engine == DictationSettings.optimizedEngine { return "豆包云端识别" }
        if model.settings.dictation.engine == DictationSettings.chatterflyEngine { return "Chatterfly 云端识别" }
        return RecognizerChoice(rawValue: model.settings.dictation.engine)?.isLocal == true ? "本机识别" : "云端识别"
    }
}
