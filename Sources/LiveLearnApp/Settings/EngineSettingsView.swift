import SwiftUI
import CaptionDomain
import ProviderAdapters
import EngineKit
import LocalEngine
import CloudEngine
import WhisperEngine

/// 设置 › 引擎 (0.3): which recognizer, which translator, with their addresses, models and keys.
/// Same paper as the other pages. A key is pasted once and goes to the Keychain; the row then
/// only says that one is there. Nothing here talks to a service until the user presses
/// 测试翻译 (one short request) or starts a session.
struct EngineSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsPage(title: "引擎", note: model.isActive ? "停止会话后可切换引擎；地址、模型和密钥的改动在下次开始时生效。" : nil) {
            recognizerGroup
            translatorGroup
            statusGroup
        }
    }

    // MARK: 识别

    private var recognizerGroup: some View {
        @Bindable var s = model.settings
        return SettingsGroup("语音识别", note: s.settingsMode.isDeveloper ? s.recognizer.note : nil,
                             help: recognizerHelp) {
            SettingRow("引擎") {
                PaperMenu(title: s.recognizer.label, font: LLFont.body, color: theme.ink, help: "识别引擎") {
                    RecognizerChoice.allCases.map { choice in
                        .row(choice.label, id: choice.rawValue, selected: s.recognizer == choice) { s.recognizer = choice }
                    }
                }
                .disabled(model.isActive)
            }
            switch s.recognizer {
            case .appleSpeech:
                SheetDivider()
                SettingRow("模型", note: "按语言下载，在「本地模型」页管理；识别不联网。") {
                    Button("打开本地模型") { model.perform(.openLocalModels) }
                        .buttonStyle(SettingsActionStyle())
                }
            case .whisperKit:
                SheetDivider()
                SettingRow("模型", note: WhisperVariant.named(s.whisperModel)?.note ?? "在「本地模型」页下载。") {
                    PaperMenu(title: WhisperVariant.label(for: s.whisperModel) + (WhisperModelStore.isInstalled(s.whisperModel) ? "" : "（未下载）"), font: LLFont.body, color: theme.ink, help: "Whisper 模型") {
                        WhisperVariant.all.map { v in
                            .row(v.label, id: v.id, detail: "\(v.sizeMB) MB" + (WhisperModelStore.isInstalled(v.id) ? " · 已安装" : ""), selected: s.whisperModel == v.id) { s.whisperModel = v.id }
                        }
                    }
                    .disabled(model.isActive)
                }
                SheetDivider()
                SettingRow("下载与管理", note: "模型文件来自 Hugging Face，下载需要联网；识别本身不联网。") {
                    Button("打开本地模型") { model.perform(.openLocalModels) }
                        .buttonStyle(SettingsActionStyle())
                }
            case .openAIRealtime:
                // The protocol switch qualifies the address and the model under it, so it stays
                // with the engine row on the rag and the typed form then runs uninterrupted. This
                // moves it two places earlier in the Tab / VoiceOver order, on purpose: don't
                // move it back under 模型 in a later tidy-up.
                if s.settingsMode.isDeveloper {
                    SheetDivider()
                    SettingRow("兼容服务协议") {
                        Toggle("兼容服务协议", isOn: $s.realtimeLegacyProtocol).toggleStyle(QuietSwitchStyle()).labelsHidden()
                    }
                }
                if showsRealtimeAddress {
                    SheetDivider()
                    SettingRow("接口地址", layout: .below) {
                        QuietField(placeholder: "wss://api.openai.com/v1/realtime", text: $s.realtimeBaseURL)
                            .frame(maxWidth: SettingsFieldWidth.measure)
                    }
                }
                SheetDivider()
                SettingRow("模型", layout: .below) {
                    QuietField(placeholder: "gpt-4o-transcribe", text: $s.realtimeModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.realtime, title: "API Key", note: "留空时沿用「翻译 › OpenAI」保存的 Key；本机兼容服务不需要。")
            case .deepgram:
                SheetDivider()
                SettingRow("模型", layout: .below) {
                    QuietField(placeholder: "nova-3", text: $s.deepgramModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.deepgram, title: "API Key", note: nil)
            case .doubao:
                SheetDivider()
                SettingRow("资源 ID", note: "1.0 版 volc.bigasr.sauc.duration；2.0 版 volc.seedasr.sauc.duration（更便宜，只认新控制台的 API Key）。", layout: .below) {
                    QuietField(placeholder: "volc.bigasr.sauc.duration", text: $s.doubaoResourceID)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.doubaoApp, title: "App ID", note: "旧控制台的应用 ID；新控制台只有一个 API Key 时留空。")
                SheetDivider()
                CredentialRow(id: CredentialStore.doubaoToken, title: "Access Token / API Key", note: nil)
            case .paraformer:
                SheetDivider()
                SettingRow("模型", note: "paraformer-realtime-v2 或 fun-asr-realtime。", layout: .below) {
                    QuietField(placeholder: "paraformer-realtime-v2", text: $s.paraformerModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.dashscope, title: "百炼 API Key", note: "留空时沿用「翻译 › 通义千问」保存的 Key。")
            case .soniox:
                SheetDivider()
                SettingRow("模型", layout: .below) {
                    QuietField(placeholder: "stt-rt-v5", text: $s.sonioxModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.soniox, title: "API Key", note: nil)
            case .geminiLive:
                SheetDivider()
                SettingRow("模型", note: "Live 模型都是预览版，名称会变；以 ai.google.dev 的模型列表为准。", layout: .below) {
                    QuietField(placeholder: "gemini-3.5-transcribe-live", text: $s.geminiLiveModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.gemini, title: "API Key", note: "与「翻译 › Google Gemini」共用同一个 Key。")
            }
        }
    }

    /// The section's one help (round 12: rows carry none): in standard mode the engine's own
    /// note, which developer mode shows as the group note instead, then what each visible field
    /// of the OpenAI realtime form expects.
    private var recognizerHelp: String? {
        let s = model.settings
        var parts = s.settingsMode.isDeveloper ? [] : [s.recognizer.note]
        if s.recognizer == .openAIRealtime {
            if s.settingsMode.isDeveloper {
                parts.append("兼容服务协议：开启后将模型名放入地址，使用旧版会话消息。部分自建服务需要；OpenAI 官方保持关闭。")
            }
            if showsRealtimeAddress {
                parts.append("接口地址：OpenAI 使用 wss://api.openai.com/v1/realtime；兼容服务填写其提供的地址。")
            }
            parts.append("模型：填写服务提供的模型名，例如 gpt-4o-transcribe 或 gpt-4o-mini-transcribe。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private var showsRealtimeAddress: Bool {
        model.settings.settingsMode.isDeveloper || model.settings.realtimeBaseURL != "wss://api.openai.com/v1/realtime"
    }

    // MARK: 翻译

    /// As `recognizerHelp`: the engine's note in standard mode, then what the chat model field
    /// expects.
    private var translatorHelp: String? {
        let s = model.settings
        var parts = s.settingsMode.isDeveloper ? [] : [s.translator.note]
        if s.translator == .chat {
            let vendor = s.chatVendor
            if let hint = vendor.isLocalPreset ? "填写本机已加载的模型名。Ollama 可用 ollama list 查看。" : vendor.hint, !hint.isEmpty {
                parts.append("模型：" + hint)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private var translatorGroup: some View {
        @Bindable var s = model.settings
        return SettingsGroup("文字翻译", note: s.settingsMode.isDeveloper ? s.translator.note : nil,
                             help: translatorHelp) {
            SettingRow("引擎") {
                PaperMenu(title: s.translator.label, font: LLFont.body, color: theme.ink, help: "翻译引擎") {
                    TranslatorChoice.allCases.map { choice in
                        .row(choice.label, id: choice.rawValue, selected: s.translator == choice) { s.translator = choice }
                    }
                }
                .disabled(model.isActive)
            }
            switch s.translator {
            case .appleTranslation:
                SheetDivider()
                SettingRow("语言包", note: "按方向下载，在「本地模型」页管理；翻译不联网。") {
                    Button("打开本地模型") { model.perform(.openLocalModels) }
                        .buttonStyle(SettingsActionStyle())
                }
            case .chat:
                chatRows
            case .anthropic:
                SheetDivider()
                SettingRow("模型", note: "claude-opus-5 最准；claude-sonnet-5 / claude-haiku-4-5 更快更便宜。", layout: .below) {
                    QuietField(placeholder: "claude-opus-5", text: $s.anthropicModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.anthropic, title: "API Key", note: nil)
                if s.settingsMode.isDeveloper {
                    SheetDivider()
                    TranslationTestRow()
                }
            case .gemini:
                SheetDivider()
                SettingRow("模型", layout: .below) {
                    QuietField(placeholder: "gemini-2.5-flash", text: $s.geminiModel)
                        .frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                CredentialRow(id: CredentialStore.gemini, title: "API Key", note: nil)
                if s.settingsMode.isDeveloper {
                    SheetDivider()
                    TranslationTestRow()
                }
            }
            if s.settingsMode.isDeveloper && !model.blueprint.translatorIsLocal {
                SheetDivider()
                SettingRow("也翻译未定稿的句子", note: "开启后识别中的半句也会送去翻译（每 1.5 秒至多一次），字幕更连贯，请求更多。关闭时只翻译定稿的整句。") {
                    Toggle("也翻译未定稿的句子", isOn: $s.cloudPartialTranslation).toggleStyle(QuietSwitchStyle()).labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private var chatRows: some View {
        @Bindable var s = model.settings
        let vendor = s.chatVendor
        SheetDivider()
        SettingRow("服务") {
            PaperMenu(title: vendor.label, font: LLFont.body, color: theme.ink, help: "翻译服务") {
                var items: [PaperMenuItem] = []
                for group in ChatVendor.groups {
                    items.append(.section(group.title))
                    items += group.vendors.map { v in
                        .row(v.label, id: v.rawValue, selected: s.chatVendor == v) { s.chatVendor = v }
                    }
                }
                return items
            }
        }
        if s.settingsMode.isDeveloper || vendor == .custom || vendor.isLocalPreset || s.chatBaseURL(for: vendor) != vendor.defaultBaseURL {
            SheetDivider()
            SettingRow("接口地址", note: vendor == .custom ? "以 /v1 结尾的根地址；localhost 视为本机服务，不出本机。" : "预设为 \(vendor.defaultBaseURL)，可改。", layout: .below) {
                QuietField(placeholder: vendor.defaultBaseURL.isEmpty ? "http://localhost:8080/v1" : vendor.defaultBaseURL, text: Binding(
                    get: { s.chatBaseURL(for: vendor) },
                    set: { s.setChatBaseURL($0, for: vendor) }
                ))
                .frame(maxWidth: SettingsFieldWidth.measure)
            }
        }
        SheetDivider()
        SettingRow("模型", layout: .below) {
            QuietField(placeholder: vendor.defaultModel.isEmpty ? "模型名" : vendor.defaultModel, text: Binding(
                get: { s.chatModel(for: vendor) },
                set: { s.setChatModel($0, for: vendor) }
            ))
            .frame(maxWidth: SettingsFieldWidth.name)
        }
        SheetDivider()
        CredentialRow(id: CredentialStore.chat(vendor), title: "API Key", note: vendor.needsKey ? nil : "本机服务通常不需要；填了会作为 Bearer 发送。")
        if s.settingsMode.isDeveloper {
            SheetDivider()
            TranslationTestRow()
        }
    }

    // MARK: 当前状态

    private var statusGroup: some View {
        SettingsGroup("当前状态", help: "就绪检查只读取本机状态与已保存的 Key，不联网、不下载。") {
            SettingRow("数据去向") { SettingValue(model.blueprint.dataDestination) }
            SheetDivider()
            SettingRow("费用") { SettingValue(model.blueprint.isLocal ? "免费" : "会话与主动测试按服务计费") }
            ForEach(model.draftDirections, id: \.key) { d in
                SheetDivider()
                SettingRow(StatusCopy.direction(d.source, d.target), note: model.readiness[d.key]?.blocker) {
                    ReadinessValue(readiness: model.readiness[d.key], refreshing: model.readinessRefreshing)
                }
            }
            SheetDivider()
            SettingRow("就绪检查") {
                Button(model.readinessRefreshing ? "正在检查…" : "重新检查") { model.refreshEngineReadiness() }
                    .buttonStyle(SettingsActionStyle())
                    .disabled(model.readinessRefreshing)
            }
        }
    }
}

/// One API key: pasted once, kept in the Keychain, shown afterwards only as "已保存 · sk-…abcd".
struct CredentialRow: View {
    let id: String
    let title: String
    let note: String?
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var status = ""
    @State private var statusIsError = false
    @State private var confirmDeletion = false
    /// "已保存 · sk-…abcd" or nil, read from the Keychain once per row, not per keystroke.
    @State private var storedHint: String?

    var body: some View {
        SettingRow(title, note: note, layout: .below) {
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                HStack(spacing: LLMetrics.space(4)) {
                    QuietField(placeholder: storedHint == nil ? "粘贴 Key" : "粘贴新的 Key 以替换", text: $draft, secure: true, onSubmit: saveCredential)
                        .frame(maxWidth: SettingsFieldWidth.name)
                        .accessibilityLabel(title)
                    Button("保存", action: saveCredential)
                    .buttonStyle(SettingsActionStyle())
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("保存到钥匙串 · 回车")
                    if storedHint != nil {
                        Button("删除…") { confirmDeletion = true }
                        .buttonStyle(SettingsActionStyle(tint: theme.brick))
                    }
                }
                // Only when it says something: an empty field needs no "未保存" under it, and no
                // blank line either — held open for a first save, it added 20 pt under every
                // empty key row and broke the group's rhythm (68 pt to the next label, not 48).
                // The row grows once, on that save, with the line the user asked for.
                if let line = status.isEmpty ? storedHint : status {
                    Text(line)
                        .font(LLFont.label)
                        .foregroundStyle(statusIsError ? theme.brick : theme.ink2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .alert("删除已保存的\(title)？", isPresented: $confirmDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                do {
                    try CredentialStore.delete(id)
                    storedHint = nil; status = "已从钥匙串删除"; statusIsError = false
                    model.settings.credentialsVersion += 1
                } catch { status = "删除失败：\(error)"; statusIsError = true }
            }
        } message: { Text("后续使用此服务时需要重新填写密钥。") }
        .task(id: id) {
            storedHint = CredentialStore.load(id).map { CredentialStore.hint($0) }
            status = ""
            draft = ""
            statusIsError = false
        }
    }

    private func saveCredential() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try CredentialStore.save(id, key: draft)
            storedHint = CredentialStore.hint(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            draft = ""; status = "已保存到钥匙串；不会写入日志或诊断包"; statusIsError = false
            model.settings.credentialsVersion += 1
        } catch { status = "保存失败：\(error)"; statusIsError = true }
    }
}

/// "测试翻译": one short sentence through the configured translator, on an explicit click.
struct TranslationTestRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    private var activity: TranslationTestActivity { model.translationTestActivity }

    var body: some View {
        SettingRow("测试翻译", note: "发送一句英文测试文本，可能产生服务费用。", layout: .below) {
            VStack(alignment: .leading, spacing: 8) {
            Button(activity.running ? "正在测试…" : "发送一句") { run() }
                .buttonStyle(SettingsActionStyle())
                .disabled(activity.running)
            if !activity.configuration.isEmpty {
                SettingsNote(activity.configuration)
            }
            // Words only: a failure is written in brick and starts with what failed, so the
            // circled check / exclamation glyphs said nothing the line does not.
            if !activity.result.isEmpty {
                Text(activity.result)
                    .font(LLFont.label).foregroundStyle(activity.failed ? theme.brick : theme.ink2)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            }
        }
    }

    private func run() {
        guard !activity.running else { return }
        activity.running = true
        activity.result = ""
        activity.failed = false
        let bp = model.blueprint
        let source = "en"
        let target = LanguageCatalog.canonical(model.settings.listenTargetLanguage) == "en" ? "zh-Hans" : model.settings.listenTargetLanguage
        let sample = "Please do not restart the server yet."
        activity.configuration = bp.summary + " · " + StatusCopy.direction(source, target)
        Task {
            let started = Date()
            do {
                let translator = try bp.makeTranslator()
                try await translator.prepare(source: source, target: target)
                let text = try await translator.translate(sample, source: source, target: target, isFinal: true)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                activity.failed = text.isEmpty
                activity.result = text.isEmpty ? "服务返回了空译文（\(ms) ms）" : "「\(sample)」→「\(text)」 · \(ms) ms"
            } catch let error as ProviderError {
                activity.result = "失败：\(error.message)"; activity.failed = true
            } catch {
                activity.result = "失败：\(error.localizedDescription)"; activity.failed = true
            }
            activity.running = false
        }
    }
}
