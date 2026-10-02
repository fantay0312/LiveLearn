import SwiftUI
import AppKit
import Translation
import Speech
import CaptionDomain
import MacAudio
import LocalEngine
import WhisperEngine
import SessionStorage

/// Settings content shared by the in-window modal and the static preview renderer.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender

    static let size = LiveLearnSettingsPage.windowSize
    static let contentTopInset: CGFloat = 52
    /// The scroll edge. The page dissolves over these 16 pt — one line of body text — wherever
    /// the card cuts it, so a clipped row reads as "there is more below" instead of a control
    /// sliced in half. Shorter than both of the page's own insets (52 pt above the title, 32 pt
    /// below the last row), so at rest and at the end of the scroll the band holds nothing but
    /// empty ground and the page looks exactly as it did; `SettingsModalHostTests` pins that.
    static let scrollEdgeFade: CGFloat = LLMetrics.space(4)

    var body: some View {
        @Bindable var settings = model.settings
        HStack(spacing: 0) {
            nav(selection: $settings.requestedSettingsTab)
            // The pane's width decides where the 576 pt column sits (`contentGutter`): centred,
            // so the page has one axis instead of a column against the rail and a dead band at
            // the right. A reader, not a measured state, so offscreen renders lay out the same.
            GeometryReader { pane in
                let gutter = LiveLearnSettingsPage.contentGutter(pane: pane.size.width)
                Group {
                    if settings.requestedSettingsTab == .appearance {
                        AppearanceSettings()
                    } else if settings.requestedSettingsTab == .textTranslation && !staticRender && settings.modules.isEnabled(.textTranslation) {
                        EmbeddedTranslationSettings(section: UnifiedSettingsPresentation.shared.translationSection,
                                                    requestID: UnifiedSettingsPresentation.shared.translationSectionRequestID,
                                                    developerMode: settings.settingsMode.isDeveloper)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollContainer(showsIndicators: true) {
                                page(settings.requestedSettingsTab)
                                    .frame(maxWidth: LiveLearnSettingsPage.contentMeasure, alignment: .leading)
                                    .padding(.leading, gutter)
                                    .padding(.top, Self.contentTopInset)
                                    .padding(.bottom, LLMetrics.space(6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("settings-top")
                            }
                            .mask { SettingsScrollEdge(fade: Self.scrollEdgeFade) }
                            .onChange(of: settings.requestedSettingsTab) { _, _ in proxy.scrollTo("settings-top", anchor: .top) }
                            .onChange(of: settings.settingsScrollRequest) { _, _ in proxy.scrollTo("settings-top", anchor: .top) }
                        }
                    }
                }
                .environment(\.settingsContentGutter, gutter)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.settingsInteractionEnabled, true)
        // One static sky shared with the translation helper; the only live canvas in the
        // modal is the sidebar's star rail.
        .background {
            theme.ground
            SettingsSky(dark: theme.isDark)
        }
        // On the rail's brand line, so the card's two top corners start on one line.
        .overlay(alignment: .topTrailing) {
            SettingsModalCloseButton { UnifiedSettingsPresentation.shared.dismiss() }
                .padding(.top, LiveLearnSettingsPage.brandLineCenterY - SettingsModalCloseButton.side / 2)
                .padding(.trailing, LiveLearnSettingsPage.closeColumn - SettingsModalCloseButton.side)
        }
    }

    private func nav(selection: Binding<SettingsTab>) -> some View {
        LiveLearnSettingsSidebar(selection: selection.wrappedValue == .diagnostics && !model.settings.settingsMode.isDeveloper
                                 ? .privacy : selection.wrappedValue.navigationPage ?? .sources,
                                 dark: theme.isDark, select: { page in
            NSApp.keyWindow?.makeFirstResponder(nil)
            selection.wrappedValue = page.settingsTab
        }, scrollable: !staticRender, mode: model.settings.settingsMode, setMode: { model.settings.settingsMode = $0 }) { index in
            HostSettingsRail(selectionIndex: index, mode: model.settings.settingsMode)
        }
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        switch tab {
        case .modules: ModuleSettings()
        case .sources: SourcesSettings()
        case .language: LanguageSettings()
        case .engine: EngineSettings()
        case .localModels: LocalModelSettings()
        case .vocabulary: VocabularySettings()
        case .appearance: AppearanceSettings()
        case .shortcuts: ShortcutSettings()
        case .privacy: PrivacySettings()
        case .diagnostics: DiagnosticsSettings()
        case .theme: ExplorationThemeSettings()
        case .browserExtension:
            if model.settings.modules.isEnabled(.browserExtension) { BrowserExtensionSettings() }
            else { ModuleMissingView(module: .browserExtension) }
        case .dictation:
            if model.settings.modules.isEnabled(.dictation) { DictationSettingsView() }
            else { ModuleMissingView(module: .dictation) }
        case .textTranslation:
            ModuleMissingView(module: .textTranslation)
        }
    }
}

/// The host's clock for the shared star rail: `LuminousMotion` (window and app visibility
/// gates) at `SettingsRailMotion.flightRate` for `flightWindow` after a selection change and
/// `restRate` while the cluster only drifts — the policy itself lives in the shared file, so
/// this process and the helper cannot disagree about it.
/// Stationary (no flight, no drift, twinkle at time 0) under Reduce Motion, in offscreen
/// renders, and while the translation helper's panel covers this card at opacity 0 — otherwise
/// two rails would tick for one visible sidebar.
private struct HostSettingsRail: View {
    let selectionIndex: Int
    let mode: SettingsMode
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = SettingsRailMotion()
    @State private var flying = false

    private var stationary: Bool { staticRender || reduceMotion }

    var body: some View {
        LuminousMotion(active: !stationary, rate: flying ? SettingsRailMotion.flightRate : SettingsRailMotion.restRate) { time in
            SettingsRailCanvas(points: motion.sample(time: time, selection: selectionIndex, stationary: stationary, mode: mode),
                               time: stationary ? 0 : time, dark: theme.isDark)
        }
        .task(id: selectionIndex) {
            guard !stationary else { return }
            flying = true
            try? await Task.sleep(for: .seconds(SettingsRailMotion.flightWindow))
            flying = false
        }
    }
}

/// Page body: title block, then groups 32pt apart (the whitespace is what separates groups now
/// that nothing is boxed).
struct SettingsPage<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(6)) {
            SettingsPageTitle(text: title, note: note)
            content()
        }
    }
}

/// Both ends of the settings column dissolve over `fade` points. It is a mask, not a painted
/// gradient (设计语言 §2 bans gradient fills): nothing new is drawn, the page's own ink thins
/// out, and the static sky behind it keeps exactly its brightness. It is the grammar the surface
/// already uses — the sidebar rule fades at its two ends, a row rule fades over its last tenth —
/// applied to the page itself: a line that is cut is drawn fading, a line that ends is drawn
/// ending.
///
/// No scroll offset and no measurement, so the window and `ImageRenderer` draw the same thing:
/// the page reserves 52 pt above its title and 32 pt below its last row, both larger than
/// `fade`, so at rest and at the end of the scroll the band covers empty ground. Ink can only
/// enter it where the card is actually cutting the page. The height never changes, so nothing
/// here animates under any accessibility setting. 字幕外观's inspector uses it too.
struct SettingsScrollEdge: View {
    let fade: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
        .accessibilityHidden(true)
    }
}

struct SourcesSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var s = model.settings
        SettingsPage(title: "音源与设备", note: model.isActive ? "停止会话后可修改设备与采集范围。" : nil) {
            SettingsGroup("麦克风", help: "记住已选麦克风。设备不可用时会提示重新选择，不会自动换用其他设备。") {
                SettingRow("设备") {
                    MicrophoneMenu(font: LLFont.body, color: theme.ink)
                        .disabled(model.isActive)
                }
                SheetDivider()
                SettingRow("权限") {
                    // A state and the action on it: 24 pt apart, as on 本地模型.
                    HStack(spacing: LLMetrics.space(5)) {
                        SettingValue(PermissionCenter.microphoneStatusText())
                        if MicrophoneCapture.authorizationStatus == .denied {
                            Button("打开系统设置") { model.perform(.openMicrophoneSettings) }
                                .buttonStyle(SettingsActionStyle())
                        }
                    }
                }
            }
            SettingsGroup("应用与系统声",
                          help: "默认采集全部应用，排除本软件。勾选应用后只采集所选应用，混为一条通道；应用尚未出声时等待，采集失败不会扩大范围。\n\n系统录音权限：首次采集时由 macOS 询问。也可前往「系统设置 › 隐私与安全性 › 录屏与系统录音」授权。拒绝权限将无法采集。") {
                SettingRow("采集范围", note: "仅采集所选范围；不能区分浏览器标签页。") {
                    ComputerSourceMenu(font: LLFont.body, color: theme.ink)
                        .disabled(model.isActive)
                }
                SheetDivider()
                SettingRow("系统录音权限", note: "授权后请重新开始会话。") {
                    Button("打开系统设置") { model.perform(.openAudioCaptureSettings) }
                        .buttonStyle(SettingsActionStyle())
                }
            }
            SettingsGroup("自检") {
                SettingRow("检查音源", note: "采集 3 秒，不识别、不保存。") {
                    Button(model.isCheckingSource ? "正在检查…" : "听 3 秒") { model.runSourceCheck() }
                        .buttonStyle(SettingsActionStyle())
                        .disabled(!model.hasSource || model.isCheckingSource || model.isActive)
                }
            }
            SettingsGroup("朗读译文", note: "朗读时会暂时静音麦克风。", help: "使用系统语音朗读定稿译文；延迟过大时跳过旧句。系统声音采集会排除本软件。") {
                SettingRow("电脑里的声音") {
                    Toggle("朗读电脑里的声音", isOn: $s.readAloudComputer).toggleStyle(QuietSwitchStyle()).labelsHidden()
                }
                SheetDivider()
                SettingRow("我说的话") {
                    Toggle("朗读我说的话", isOn: $s.readAloudMicrophone).toggleStyle(QuietSwitchStyle()).labelsHidden()
                }
            }
        }
    }
}

struct LanguageSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var s = model.settings
        SettingsPage(title: "语言", note: model.isActive ? "停止会话后可修改默认语言；当前方向可在首页的音源设置中调整。" : nil) {
            SettingsGroup("收听（应用 / 系统声）") {
                SettingRow("源语言", note: "「自动识别」只有会检测语言的识别引擎才接受；Apple 本机识别需要指定。") { LanguageMenu(selection: $s.listenSourceLanguage, allowAuto: true, help: "收听的源语言") }
                SheetDivider()
                SettingRow("目标语言") { LanguageMenu(selection: $s.listenTargetLanguage, help: "收听的目标语言") }
                readiness(s.listenSourceLanguage, s.listenTargetLanguage)
            }
            .disabled(model.isActive)
            SettingsGroup("我说的话（麦克风）") {
                SettingRow("源语言") { LanguageMenu(selection: $s.micSourceLanguage, allowAuto: true, help: "我说的话的源语言") }
                SheetDivider()
                SettingRow("目标语言") { LanguageMenu(selection: $s.micTargetLanguage, help: "我说的话的目标语言") }
                readiness(s.micSourceLanguage, s.micTargetLanguage)
            }
            .disabled(model.isActive)
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                if let blocker = model.startBlocker {
                    SettingsNote(blocker, color: theme.brick)
                }
                SettingsNote(model.blueprint.isLocal ? "本机引擎按已安装的识别模型与翻译语言包开放方向；缺少的部分在「本地模型」里下载。" : "云端引擎的语言范围以各服务为准；一个方向能否开始，以下面的就绪状态为准。")
            }
        }
    }

    @ViewBuilder
    private func readiness(_ source: String, _ target: String) -> some View {
        SheetDivider()
        SettingRow(model.blueprint.summary, note: model.readiness[AppModel.pairKey(source, target)]?.blocker) {
            ReadinessValue(readiness: model.readiness[AppModel.pairKey(source, target)], refreshing: model.readinessRefreshing)
        }
    }
}

/// "就绪" in moss, or what is missing in ochre.
struct ReadinessValue: View {
    let readiness: EngineReadiness?
    let refreshing: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        if let readiness {
            SettingValue(readiness.summary, color: readiness.isReady ? theme.moss : theme.ochre)
                .help(readiness.blocker ?? "识别与翻译均已就绪")
        } else {
            PendingValue(refreshing: refreshing)
        }
    }
}

/// No answer yet — not checked, or being checked: `ink3`, quieter than any real state (a state
/// is `ink2`, or `ink3` beside its action), as 不可用 is. In `ink2` the eight 未检查 of an
/// unchecked 本地模型 page outshone the real 可下载 · 76 MB beside them.
struct PendingValue: View {
    let refreshing: Bool
    @Environment(\.theme) private var theme

    var body: some View { SettingValue(refreshing ? "正在检查" : "未检查", color: theme.ink3) }
}

/// Speech assets and translation language packs. Nothing downloads without a click here; the
/// system decides sizes and shows its own confirmation for translation packs.
struct LocalModelSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationDirectionKey: String?

    private var directions: [LanguageDirection] {
        Self.translationDirections(for: [
            LanguageDirection(source: model.settings.listenSourceLanguage, target: model.settings.listenTargetLanguage),
            LanguageDirection(source: model.settings.micSourceLanguage, target: model.settings.micTargetLanguage)
        ])
    }

    static func translationDirections(for configured: [LanguageDirection]) -> [LanguageDirection] {
        var seen = Set<String>()
        var out: [LanguageDirection] = []
        for d in configured {
            let sources = d.source == LanguageCatalog.auto ? LanguageCatalog.codes : [d.source]
            for source in sources {
                let pair = LanguageDirection(source: LanguageCatalog.canonical(source), target: LanguageCatalog.canonical(d.target))
                if pair.source != pair.target, seen.insert(pair.key).inserted { out.append(pair) }
            }
        }
        return out
    }

    /// Recognition assets to list: the languages in use first, then the common set. Asking the
    /// OS about all thirty at once is slow and mostly answers questions nobody asked.
    private var speechLanguages: [String] {
        var out: [String] = []
        let configured = [model.settings.listenSourceLanguage, model.settings.micSourceLanguage].filter { $0 != LanguageCatalog.auto }
        for code in configured + LanguageCatalog.common.map(\.code) where !out.contains(code) { out.append(code) }
        return out
    }

    var body: some View {
        SettingsPage(title: "本地模型") {
            SettingsGroup("识别模型（Apple SpeechAnalyzer）", note: LocalEngineAvailability.isSupportedOS ? "模型由 macOS 管理，下载体积以系统为准（通常几百 MB），一次下载后所有应用共用；下载需要联网，识别本身不联网。" : "这台电脑的系统没有本机识别；升级后这里会列出可下载的语言。") {
                if !LocalEngineAvailability.isSupportedOS {
                    SettingRow("状态") { SettingValue("需要 macOS 26") }
                } else {
                    ForEach(Array(speechLanguages.enumerated()), id: \.element) { index, code in
                        if index > 0 { SheetDivider() }
                        speechRow(code)
                    }
                }
            }
            SettingsGroup("Whisper 模型（WhisperKit，本机运行）", note: "开源 Whisper 的 CoreML 版本，从 Hugging Face（argmaxinc/whisperkit-coreml）下载到本机，macOS 15 即可；识别不联网。下载后会加载一次让系统编译，大模型要几十秒。") {
                ForEach(Array(WhisperVariant.all.enumerated()), id: \.element.id) { index, v in
                    if index > 0 { SheetDivider() }
                    whisperRow(v)
                }
            }
            SettingsGroup("翻译语言包（Apple Translation）", note: "语言包由系统下载与管理。源语言选「自动」时，下面列出可选方向，只需下载会用到的语言；未安装的方向无法离线翻译。点「下载」后 macOS 会弹出确认，显示体积。") {
                ForEach(Array(directions.enumerated()), id: \.element.key) { index, d in
                    if index > 0 { SheetDivider() }
                    translationRow(d.source, d.target)
                }
                if directions.isEmpty {
                    SettingRow("尚无方向", note: "在「语言」里选择方向后，这里显示对应语言包。")
                }
            }
            SettingsGroup {
                SettingRow("本机状态", note: "查询只读取本机状态，不会触发下载。") {
                    Button(model.localModelActivity.refreshing ? "正在检查…" : "重新检查") { refresh() }
                        .buttonStyle(SettingsActionStyle())
                        .disabled(model.localModelActivity.refreshing)
                }
            }
        }
        .translationTask(translationConfig) { session in
            guard let cfg = translationConfig else { return }
            let key = translationDirectionKey ?? "\(cfg.source?.minimalIdentifier ?? "")>\(cfg.target?.minimalIdentifier ?? "")"
            do {
                try await Self.prepare(TranslationSessionBox(session))
                model.localModelActivity.notes[key] = "语言包已就绪"
            } catch {
                model.localModelActivity.notes[key] = "未完成：\(error.localizedDescription)"
            }
            translationConfig = nil
            translationDirectionKey = nil
            refresh()
        }
        .task { refresh() }
    }

    /// `TranslationSession` is not Sendable; the SwiftUI callback hands it to us on the main
    /// actor, and `prepareTranslation` must run off it. The box carries it across once.
    private final class TranslationSessionBox: @unchecked Sendable {
        let session: TranslationSession
        init(_ s: TranslationSession) { session = s }
    }

    nonisolated private static func prepare(_ box: TranslationSessionBox) async throws {
        try await box.session.prepareTranslation()
    }

    private func name(_ code: String) -> String { StatusCopy.language(code) }

    /// Between a model's state and the action on it: far enough that 下载 reads as its own word
    /// after "可下载 · 76 MB", not as the last word of the state.
    private static let actionGap = LLMetrics.space(5)

    /// A state with an action beside it steps down to `ink3`, so the one word in the row that
    /// can be pressed leads; at `ink2` the two were the same ink and only the action's weight
    /// told them apart. A state with nothing beside it keeps the value ink.
    private func state(_ text: String, beside action: Bool) -> some View {
        SettingValue(text, color: action ? theme.ink3 : nil)
    }

    @ViewBuilder
    private func speechRow(_ code: String) -> some View {
        let state = model.localModelActivity.speechStates[code]
        SettingRow(name(code), note: model.localModelActivity.notes["speech:\(code)"]) {
            HStack(spacing: Self.actionGap) {
                if let p = model.localModelActivity.speechProgress[code] {
                    ProgressView(value: p).tint(theme.accent).controlSize(.small).frame(width: 90)
                    Text("\(Int(p * 100))%").font(LLFont.body.monospacedDigit()).foregroundStyle(theme.ink2)
                } else if let state {
                    self.state(state.label, beside: state == .downloadable)
                    if state == .downloadable {
                        Button("下载") { downloadSpeech(code) }
                            .buttonStyle(SettingsActionStyle())
                    }
                } else {
                    PendingValue(refreshing: model.localModelActivity.refreshing)
                }
            }
        }
    }

    @ViewBuilder
    private func translationRow(_ source: String, _ target: String) -> some View {
        let key = AppModel.pairKey(source, target)
        SettingRow(StatusCopy.direction(source, target), note: model.localModelActivity.notes[key]) {
            HStack(spacing: Self.actionGap) {
                if translationConfig != nil, translationDirectionKey == key {
                    SettingValue("等待系统确认…")
                } else if let state = model.localModelActivity.translationStates[key] {
                    self.state(state.label, beside: state == .downloadable)
                    if state == .downloadable {
                        Button("下载") {
                            translationDirectionKey = key
                            translationConfig = TranslationSession.Configuration(source: LocalLanguage.translationLanguage(for: source), target: LocalLanguage.translationLanguage(for: target))
                        }
                        .buttonStyle(SettingsActionStyle())
                        .disabled(translationConfig != nil)
                    }
                } else {
                    PendingValue(refreshing: model.localModelActivity.refreshing)
                }
            }
        }
    }

    @ViewBuilder
    private func whisperRow(_ v: WhisperVariant) -> some View {
        let inUse = model.settings.recognizer == .whisperKit && model.settings.whisperModel == v.id
        SettingRow(v.label + (inUse ? " · 使用中" : ""), note: model.localModelActivity.whisperNotes[v.id] ?? v.note) {
            HStack(spacing: Self.actionGap) {
                if let p = model.localModelActivity.whisperProgress[v.id] {
                    ProgressView(value: p).tint(theme.accent).controlSize(.small).frame(width: 90)
                    Text("\(Int(p * 100))%").font(LLFont.body.monospacedDigit()).foregroundStyle(theme.ink2)
                } else if model.localModelActivity.whisperPreparing.contains(v.id) {
                    SettingValue("正在准备（首次编译）…")
                } else if let bytes = model.localModelActivity.whisperInstalled[v.id] {
                    state("已安装 · \(Int(bytes / 1_048_576)) MB", beside: true)
                    Button("删除") { deleteWhisper(v.id) }
                        .buttonStyle(SettingsActionStyle(tint: theme.brick))
                        .disabled(inUse && model.isActive)
                } else {
                    state("可下载 · \(v.sizeMB) MB", beside: true)
                    Button("下载") { downloadWhisper(v.id) }
                        .buttonStyle(SettingsActionStyle())
                }
            }
        }
    }

    static func installedWhisper() -> [String: Int64] {
        var installed: [String: Int64] = [:]
        for v in WhisperVariant.all where WhisperModelStore.isInstalled(v.id) {
            installed[v.id] = WhisperModelStore.installedBytes(v.id)
        }
        return installed
    }

    private func refreshWhisper() {
        model.localModelActivity.whisperInstalled = Self.installedWhisper()
    }

    private func downloadWhisper(_ id: String) {
        guard model.localModelActivity.whisperProgress[id] == nil, !model.localModelActivity.whisperPreparing.contains(id) else { return }
        model.localModelActivity.whisperProgress[id] = 0
        model.localModelActivity.whisperNotes[id] = nil
        let box = ProgressBox()
        Task {
            let poll = Task {
                while !Task.isCancelled {
                    model.localModelActivity.whisperProgress[id] = box.value
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            do {
                _ = try await WhisperModelStore.download(id) { box.value = $0 }
                poll.cancel()
                model.localModelActivity.whisperProgress[id] = nil
                model.localModelActivity.whisperPreparing.insert(id)
                try await WhisperModelStore.prepare(id)
                model.localModelActivity.whisperPreparing.remove(id)
                model.localModelActivity.whisperNotes[id] = "已下载并准备好"
            } catch {
                poll.cancel()
                model.localModelActivity.whisperProgress[id] = nil
                model.localModelActivity.whisperPreparing.remove(id)
                model.localModelActivity.whisperNotes[id] = "未完成：\(error.localizedDescription)"
            }
            refreshWhisper()
            model.refreshEngineReadiness()
        }
    }

    private func deleteWhisper(_ id: String) {
        Task {
            do {
                try await WhisperModelStore.delete(id)
                model.localModelActivity.whisperNotes[id] = "已删除"
            } catch {
                model.localModelActivity.whisperNotes[id] = "删除失败：\(error.localizedDescription)"
            }
            refreshWhisper()
            model.refreshEngineReadiness()
        }
    }

    private func refresh() {
        guard !model.localModelActivity.refreshing else { return }
        model.localModelActivity.refreshing = true
        refreshWhisper()
        let dirs = directions
        let codes = speechLanguages
        Task {
            var speech: [String: AssetState] = [:]
            for code in codes {
                speech[code] = await LocalEngineAvailability.speechState(language: code)
            }
            var translation: [String: AssetState] = [:]
            for d in dirs {
                translation[AppModel.pairKey(d.source, d.target)] = await LocalEngineAvailability.translationState(source: d.source, target: d.target)
            }
            model.localModelActivity.speechStates = speech
            model.localModelActivity.translationStates = translation
            model.localModelActivity.refreshing = false
            model.refreshEngineReadiness()
        }
    }

    private func downloadSpeech(_ code: String) {
        guard #available(macOS 26, *) else { return }
        guard model.localModelActivity.speechProgress[code] == nil else { return }
        model.localModelActivity.speechProgress[code] = 0
        model.localModelActivity.notes["speech:\(code)"] = nil
        Task {
            do {
                guard let request = try await LocalEngineAvailability.speechInstallationRequest(language: code) else {
                    model.localModelActivity.notes["speech:\(code)"] = "已安装，无需下载"
                    model.localModelActivity.speechProgress[code] = nil
                    refresh()
                    return
                }
                let progress = request.progress
                let poll = Task {
                    while !Task.isCancelled {
                        model.localModelActivity.speechProgress[code] = progress.fractionCompleted
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                }
                defer { poll.cancel() }
                try await request.downloadAndInstall()
                poll.cancel()
                model.localModelActivity.speechProgress[code] = nil
                model.localModelActivity.notes["speech:\(code)"] = "已下载"
            } catch {
                model.localModelActivity.speechProgress[code] = nil
                model.localModelActivity.notes["speech:\(code)"] = "下载失败：\(error.localizedDescription)"
            }
            refresh()
        }
    }
}


struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var s = model.settings
        SettingsPage(title: "隐私与记录") {
            SettingsGroup("记录", note: "导出格式：纯文本、Markdown、SRT、WebVTT；时间为会话相对时间，未完成的句子会标注。") {
                SettingRow("自动保存会话到本机", note: s.autoSaveSessions
                           ? "每次会话结束时把正文写入本机记录文件夹；进行中每 5 秒写一次临时文件，意外退出后下次启动会恢复为「未正常结束」的记录。不保存原始音频。"
                           : "默认关闭：结束后的记录只留在内存，退出软件即消失。你可以在侧栏「记录」里对单次会话点「保存」或「导出」。不保存原始音频。") {
                    Toggle("自动保存会话到本机", isOn: $s.autoSaveSessions).toggleStyle(QuietSwitchStyle()).labelsHidden()
                }
                SheetDivider()
                SettingRow("位置") {
                    HStack(spacing: LLMetrics.space(5)) {
                        // A word, not an em dash, when there is no record store (previews and
                        // renders); 打开 would open nothing then, so it says so.
                        SettingValue(model.sessionsFolderURL?.path ?? "不可用", color: model.sessionsFolderURL == nil ? theme.ink3 : nil)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .help(model.sessionsFolderURL?.path ?? "")
                        Button("打开") { model.perform(.openSessionsFolder) }
                            .buttonStyle(SettingsActionStyle())
                            .disabled(model.sessionsFolderURL == nil)
                    }
                }
                SheetDivider()
                SettingRow("已保存") { SettingValue("\(model.records.filter(\.saved).count) 条") }
                SheetDivider()
                SettingRow("删除全部已保存的记录", note: "文件会从本机记录文件夹移除，不可恢复。未保存的内存记录不受影响。") {
                    Button("删除全部…") { confirmDeleteAll = true }
                        .buttonStyle(SettingsActionStyle(tint: theme.brick))
                        .disabled(model.records.filter(\.saved).isEmpty)
                        .confirmationDialog("删除全部已保存的记录？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                            Button("删除", role: .destructive) { model.deleteAllSavedRecords() }
                            Button("取消", role: .cancel) {}
                        } message: {
                            Text("文件会从本机记录文件夹移除，不可恢复。未保存的内存记录不受影响。")
                        }
                }
            }
            SettingsGroup("运行") {
                SettingRow("关闭主窗口后继续在菜单栏运行") {
                    Toggle("关闭主窗口后继续在菜单栏运行", isOn: $s.keepRunningWhenWindowCloses).toggleStyle(QuietSwitchStyle()).labelsHidden()
                }
            }
            if !s.settingsMode.isDeveloper { DiagnosticsExportSettings() }
            SettingsNote("转写可能涉及他人。使用前请遵守所在地和会议组织的要求；本软件不承诺满足所有司法辖区的录音合规。")
        }
    }
}

struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let lanes = model.liveSnapshot.lanes
        SettingsPage(title: "诊断") {
            if model.settings.settingsMode.isDeveloper {
            SettingsGroup("通道") {
                if lanes.isEmpty {
                    SettingRow("尚无通道", note: "开始会话后这里列出每条通道的采集与连接状态。")
                }
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                    if index > 0 { SheetDivider() }
                    SettingRow(lane.configuration.source.tag, note: "回调 \(lane.capture.callbackCount) · 队列 \(StatusCopy.millis(lane.capture.queuedNs)) · 丢弃 \(StatusCopy.seconds(lane.capture.droppedNs))\n引擎 \(lane.providerName) · \(StatusCopy.link(lane.providerLink)) · 代次 \(lane.providerEpoch) · 重连 \(lane.reconnectAttempts)", monospacedNote: true) {
                        SettingValue("\(StatusCopy.lane(lane)) · \(lane.capture.format?.summary ?? "—")")
                    }
                }
            }
            }
            DiagnosticsExportSettings()
        }
    }
}

private struct DiagnosticsExportSettings: View {
    @Environment(AppModel.self) private var model
    @State private var exported = ""

    /// What the package holds: the row's own note, kept above the result of an export.
    private static let contents = "诊断包包含运行状态与错误信息，不含密钥、音频或转写正文。"

    var body: some View {
        SettingsGroup("问题排查") {
            SettingRow("导出诊断包", note: exported.isEmpty ? Self.contents : Self.contents + "\n" + exported) {
                Button("导出") { exported = DiagnosticsExporter.export(model.liveSnapshot) }
                    .buttonStyle(SettingsActionStyle())
            }
        }
    }
}
