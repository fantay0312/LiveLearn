import SwiftUI
import WhisperEngine

struct OverlayEngineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var recognizer: RecognizerChoice = .appleSpeech
    @State private var whisperModel = WhisperVariant.defaultID
    @State private var translator: TranslatorChoice = .appleTranslation
    @State private var applying = false
    @State private var error: String?

    private var candidate: EngineBlueprint {
        var result = model.blueprint
        result.recognizer = recognizer
        result.whisper.variant = whisperModel
        result.translator = translator
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("字幕引擎").font(.headline)
            PaperChoiceRow(label: "识别", selection: $recognizer, options: RecognizerChoice.allCases, title: { $0.label }, help: "选择识别引擎")
            if recognizer == .whisperKit {
                PaperChoiceRow(label: "模型", selection: $whisperModel,
                    options: WhisperVariant.all.map(\.id) + (WhisperVariant.named(whisperModel) == nil ? [whisperModel] : []),
                    title: { id in (WhisperVariant.named(id)?.label ?? id) + (WhisperModelStore.isInstalled(id) ? " · 已安装" : " · 未下载") }, help: "选择 Whisper 模型")
                HStack {
                    Text(WhisperModelStore.isInstalled(whisperModel) ? "所选模型已安装" : "请先下载所选模型，再应用。")
                        .foregroundStyle(WhisperModelStore.isInstalled(whisperModel) ? theme.ink2 : theme.ochre)
                    Spacer()
                    Button("管理模型…") { showSettings(.localModels) }
                        .buttonStyle(InlineButtonStyle())
                }
                .font(.system(size: 12))
            }
            Text(candidate.recognizerIsLocal ? "语音识别在本机处理。" : "音频将发送到 \(candidate.recognizerName)，按服务商规则计费。")
                .font(.system(size: 12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            PaperChoiceRow(label: "翻译", selection: $translator, options: TranslatorChoice.allCases,
                title: { $0 == .chat ? model.blueprint.chat.displayName : $0.label }, help: "选择翻译引擎")
            Text(candidate.translatorIsLocal ? "译文在本机处理。" : "文本将发送到 \(candidate.translatorName)，按服务商规则计费。")
                .font(.system(size: 12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.isActive ? "切换会保留当前记录，并开始新会话。" : "用于下一次开始的会话。")
                .font(.system(size: 12)).foregroundStyle(theme.ink2)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(theme.ochre)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("配置引擎…") {
                    showSettings(.engine)
                }
                .buttonStyle(InlineButtonStyle())
                Spacer()
                Button(applying ? "正在切换…" : "应用") {
                    applying = true
                    error = nil
                    Task { @MainActor in
                        error = await model.applyOverlayEngines(recognizer: recognizer, whisperModel: whisperModel, translator: translator)
                        applying = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled((recognizer == model.settings.recognizer && translator == model.settings.translator && whisperModel == model.settings.whisperModel)
                          || (recognizer == .whisperKit && !WhisperModelStore.isInstalled(whisperModel)))
            }
        }
        .font(.system(size: 13))
        .disabled(applying)
        .onAppear {
            recognizer = model.settings.recognizer
            translator = model.settings.translator
            whisperModel = model.settings.whisperModel
        }
        .onChange(of: recognizer) { _, _ in error = nil }
        .onChange(of: translator) { _, _ in error = nil }
        .onChange(of: whisperModel) { _, _ in error = nil }
    }

    private func showSettings(_ tab: SettingsTab) {
        model.settings.requestedSettingsTab = tab
        dismiss()
        UnifiedSettingsPresentation.shared.open()
    }
}
