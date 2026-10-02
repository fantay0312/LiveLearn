import SwiftUI

/// 280pt menu bar panel (§9.3): a status label, then plain text rows in groups.
///
/// Round 12: the status line is a label that heads the panel (11/500 `ink2`), not a thirteenth
/// row in the rows' own voice — it is the one line that cannot be clicked. While audio is live
/// the app's "now" mark (`NowMark`, 2 × 10 pt) hangs in the 8 pt slot left of it, the way it
/// marks the live session in the sidebar; a dot trailing the words read as a stray bullet, a
/// fourth mark beside orbit, star and now bar. Groups are divided by the app's rule
/// (`FadingRule`: 0.5 pt, starting on the 16 pt text column, fading at its far end) instead of
/// hard full-bleed 1 pt lines heavier than the text they divide. Rows, their order, the instant
/// hover tint and the shortcut hints stay those of a native menu.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The status starts on the column the rows start on; the now mark hangs outside it,
            // centred 8 pt from the panel's edge.
            HStack(spacing: LLMetrics.space(2)) {
                Text(model.statusText).font(LLFont.labelStrong).foregroundStyle(theme.ink2).lineLimit(2)
                    .overlay(alignment: .leading) {
                        NowMark().frame(height: 10).opacity(nowOpacity).offset(x: -9)
                    }
                Spacer()
                if model.isActive {
                    SessionClock(color: theme.ink3)
                }
            }
            .padding(.horizontal, LLMetrics.space(4))
            .padding(.top, LLMetrics.space(3))
            .padding(.bottom, LLMetrics.space(2))
            rule
            // The hints at the right are the global shortcuts as configured in 设置 › 快捷键.
            let session = model.settings.hotKey(for: .toggleSession)?.display
            let pause = model.settings.hotKey(for: .togglePause)?.display
            Group {
                switch model.sessionState {
                case .idle, .completed, .failed:
                    row("开始", enabled: model.canStart, shortcut: session) { model.start() }
                case .paused:
                    row("继续", enabled: model.canPauseOrResume, shortcut: pause) { model.resume() }
                    row("停止", enabled: model.canStop, shortcut: session) { model.stop() }
                default:
                    row(SessionActionAppearance.primary(for: model.sessionState).title,
                        enabled: model.canPauseOrResume, shortcut: pause) { model.pause() }
                    row("停止", enabled: model.canStop, shortcut: session) { model.stop() }
                }
            }
            rule
            row(model.overlayVisible ? "隐藏字幕" : "显示字幕", shortcut: model.settings.hotKey(for: .toggleOverlay)?.display) { model.toggleOverlay() }
            row(model.overlayLocked ? "解锁浮层" : "锁定浮层", shortcut: model.settings.hotKey(for: .toggleLock)?.display) { model.toggleLock() }
            rule
            row("打开主窗口", shortcut: model.settings.hotKey(for: .showMainWindow)?.display) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            if model.settings.modules.isEnabled(.dictation) {
            if !model.dictation.isActive {
                row("开始语音输入", shortcut: model.settings.hotKey(for: .toggleDictation)?.display) {
                    model.dictation.startFromInterface()
                }
            }
            row("语音输入设置…") {
                model.settings.requestedSettingsTab = .dictation
                UnifiedSettingsPresentation.shared.open()
            }
            PaperMenu(title: "听写选项 · \(model.settings.dictation.languageLabel)", help: "听写选项") {
                [.section("听写语言")] + DictationLanguage.allCases.map { language in
                    .row(language.title, id: language.rawValue, selected: model.settings.dictation.language == language.rawValue) {
                        model.settings.dictation.language = language.rawValue
                    }
                } + [.divider(), .check("启用完成纠错", on: model.settings.dictation.finalCorrection) { model.settings.dictation.finalCorrection.toggle() },
                     .row("纠错设置…") { model.settings.requestedSettingsTab = .dictation; UnifiedSettingsPresentation.shared.open() },
                     .row("设置按住说话快捷键…") { model.settings.requestedSettingsTab = .shortcuts; UnifiedSettingsPresentation.shared.open() }]
            }.padding(.horizontal, LLMetrics.space(4)).frame(height: 32)
            if model.dictation.isActive {
                row("完成语音输入", enabled: model.dictation.phase == .listening) { model.dictation.finish() }
                row("取消语音输入") { model.dictation.cancel() }
            }
            }
            row("词汇库…") { model.requestVocabularyWindow() }
            if model.settings.modules.isEnabled(.textTranslation) {
            row(TranslationFeature.shared.openingActions.contains("workbench") ? "正在打开翻译工作台…" : "翻译工作台…",
                enabled: !TranslationFeature.shared.openingActions.contains("workbench")) { TranslationFeature.shared.perform("workbench", dark: theme.isDark) }
            row("截图翻译…") { TranslationFeature.shared.perform("snipTranslate", dark: theme.isDark) }
            if let error = TranslationFeature.shared.lastError {
                Text(error).font(LLFont.label).foregroundStyle(theme.brick).lineLimit(3)
                    .padding(.horizontal, LLMetrics.space(4)).padding(.vertical, LLMetrics.space(2))
                if TranslationFeature.shared.canRetry { row("重试翻译操作") { TranslationFeature.shared.retryLastOperation() } }
            }
            }
            row("设置…") {
                UnifiedSettingsPresentation.shared.open()
            }
            rule
            row("退出 LiveLearn") { NSApp.terminate(nil) }
        }
        .padding(.vertical, LLMetrics.space(1))
        .frame(width: LLMetrics.menuWidth)
        .background(theme.ground)
    }

    /// Lit while audio is flowing; at 45 % while the session connects or waits for its first
    /// audio (still — the breathing dot's clock is not carried over); nothing while paused or
    /// idle, where the words say the state.
    private var nowOpacity: Double {
        switch model.liveDotMode {
        case .live: return 1
        case .waiting: return 0.45
        case .hidden, .paused: return 0
        }
    }

    /// A group rule on the text column, with 4 pt of air on either side so the groups breathe
    /// without the rows' 32 pt pitch changing.
    private var rule: some View {
        FadingRule()
            .padding(.horizontal, LLMetrics.space(4))
            .padding(.vertical, LLMetrics.space(1))
    }

    private func row(_ title: String, enabled: Bool = true, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(LLFont.body).foregroundStyle(enabled ? theme.ink : theme.inkDisabled)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(LLFont.label).foregroundStyle(theme.ink3)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!enabled)
        .padding(.horizontal, LLMetrics.space(1))
        .frame(height: 32)
    }
}
