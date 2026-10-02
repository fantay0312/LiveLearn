import SwiftUI
import CloudEngine
import ProviderAdapters

enum DictationRefinementConfiguration {
    static func make(baseURL: String, model: String, key: String?) throws -> OpenAICompatibleConfig {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ChatVendor.isLocalHost(url)),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError(.userFixable, "请填写完整的 HTTPS API Base URL 和模型名称；本机服务可用 HTTP。")
        }
        return OpenAICompatibleConfig(vendorID: "dictation", displayName: "听写纠错", baseURL: url,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: key,
            isLocal: ChatVendor.isLocalHost(url), destination: host, temperature: 0)
    }
}

struct DictationRefinementSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelName = ""
    @State private var result: String?
    @State private var testing = false
    @State private var loaded = false
    @State private var expanded = false
    @State private var testTask: Task<Void, Never>?
    @State private var testID = UUID()

    var body: some View {
        @Bindable var settings = model.settings.dictation
        SettingsGroup("纠错", help: "完成后纠错只修复识别错误，保留原意和正确内容。") {
            SettingRow("完成后纠错") {
                Toggle("完成后纠错", isOn: $settings.finalCorrection).labelsHidden().toggleStyle(QuietSwitchStyle())
            }
            if settings.finalCorrection {
                SheetDivider()
                DictationFold(title: "纠错模型", summary: connectionSummary, expanded: $expanded) {
                    // An address fills the measure; a key and a model name take the name width.
                    SettingsSheet {
                        SettingRow("API 地址", layout: .below) {
                            QuietField(placeholder: "留空沿用现有模型", text: $baseURL).frame(maxWidth: SettingsFieldWidth.measure)
                        }
                        SheetDivider()
                        SettingRow("API Key", layout: .below) {
                            HStack(spacing: LLMetrics.space(4)) {
                                QuietField(placeholder: "API Key", text: $apiKey, secure: true)
                                    .frame(maxWidth: SettingsFieldWidth.name)
                                    .accessibilityLabel("听写纠错 API Key")
                                Button("清空") { apiKey = "" }.buttonStyle(SettingsActionStyle()).disabled(apiKey.isEmpty)
                            }
                        }
                        SheetDivider()
                        SettingRow("模型", layout: .below) {
                            QuietField(placeholder: "模型名称", text: $modelName).frame(maxWidth: SettingsFieldWidth.name)
                        }
                    }
                    HStack(spacing: LLMetrics.space(5)) {
                        Button("保存") { save() }.buttonStyle(SettingsActionStyle()).disabled(testing)
                        Button(testing ? "测试中…" : "测试连接") { test() }
                            .buttonStyle(SettingsActionStyle()).disabled(testing)
                    }
                    .onAppear {
                        guard !loaded else { return }; loaded = true
                        apiKey = CredentialStore.load("dictation.refinement") ?? ""
                    }
                    SettingsNote("地址和模型留空时沿用现有配置。清空密钥后保存即可删除。")
                }
                SettingsNote(model.blueprint.chat.isLocal && baseURL.isEmpty ? "文本在本机处理" : "识别文本会发送给所选模型")
            }
            // Saved, a test reply or a failure: an outcome, one step above the static notes.
            if let result { SettingsNote(result, color: theme.ink2) }
        }
        .disabled(model.dictation.isActive)
        .onAppear {
            baseURL = settings.refinementBaseURL; modelName = settings.refinementModel
        }
        .onChange(of: settings.finalCorrection) { _, enabled in
            if !enabled { cancelTest(); expanded = false; result = nil }
            else if needsConfiguration { expanded = true }
        }
        .onDisappear { cancelTest() }
    }

    private var connectionSummary: String {
        if !modelName.isEmpty { return modelName }
        return needsConfiguration ? "点击配置模型" : "沿用现有模型"
    }

    private var needsConfiguration: Bool {
        baseURL.isEmpty && modelName.isEmpty && model.blueprint.chat.requiresKey && (model.blueprint.chat.apiKey ?? "").isEmpty
    }

    private func save() {
        do {
            if !baseURL.isEmpty || !modelName.isEmpty { _ = try DictationRefinementConfiguration.make(baseURL: baseURL, model: modelName, key: apiKey) }
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try CredentialStore.delete("dictation.refinement") }
            else { try CredentialStore.save("dictation.refinement", key: apiKey) }
            model.settings.dictation.refinementBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            model.settings.dictation.refinementModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            result = apiKey.isEmpty ? "已保存；独立纠错密钥已清空。" : "已保存。"
        } catch { result = String(describing: error) }
    }

    private func test() {
        cancelTest()
        let id = UUID(); testID = id
        testing = true; result = nil
        testTask = Task { @MainActor in
            defer { if testID == id { testing = false } }
            do {
                let config = baseURL.isEmpty && modelName.isEmpty ? try model.dictationRefinementConfig()
                    : try DictationRefinementConfiguration.make(baseURL: baseURL, model: modelName, key: apiKey)
                let output = try await DictationCorrector(config: config).correct("请用 Python 读取 JSON，保留 API v2.0。", vocabulary: ["Python", "JSON", "API"])
                guard testID == id, !Task.isCancelled else { return }
                result = "测试返回：\(output)"
            } catch {
                guard testID == id, !Task.isCancelled else { return }
                result = "测试失败：\(error)"
            }
        }
    }

    private func cancelTest() { testID = UUID(); testTask?.cancel(); testTask = nil; testing = false }
}
