import SwiftUI

/// The 豆包输入法引擎 connection form, inside 语音输入's 引擎连接 fold: rows under rules, the
/// address across the measure and the ids and keys at the name width, actions as words.
struct OptimizedEngineSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var appKey = ""
    @State private var token = ""
    @State private var status: String?
    @State private var endpoint = ""
    @State private var appID = ""
    @State private var deviceID = ""

    var body: some View {
        SettingsSheet {
            if model.settings.settingsMode.isDeveloper {
                SettingRow("服务地址", layout: .below) {
                    QuietField(placeholder: "wss://…", text: $endpoint).frame(maxWidth: SettingsFieldWidth.measure)
                }
                SheetDivider()
                SettingRow("App ID", layout: .below) {
                    QuietField(placeholder: "App ID", text: $appID).frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
                SettingRow("设备标识", layout: .below) {
                    QuietField(placeholder: "设备标识", text: $deviceID).frame(maxWidth: SettingsFieldWidth.name)
                }
                SheetDivider()
            } else {
                SettingsNote("连接参数已配置；需要自定义地址或设备标识时，可切换开发者模式。")
                    .padding(.bottom, LLMetrics.space(1))
            }
            SettingRow("App Key", layout: .below) {
                QuietField(placeholder: "内置 App Key", text: $appKey, secure: true).frame(maxWidth: SettingsFieldWidth.name)
            }
            SheetDivider()
            SettingRow("Token（可选）", layout: .below) {
                QuietField(placeholder: "默认连接不需要", text: $token, secure: true).frame(maxWidth: SettingsFieldWidth.name)
            }
        }
        HStack(spacing: LLMetrics.space(5)) {
            Button("保存") {
                do {
                    guard URL(string: endpoint)?.scheme == "wss", URL(string: endpoint)?.host != nil,
                          let number = Int64(deviceID), number > 0, !appID.isEmpty else {
                        status = "请填写有效的 WSS 地址、App ID 和设备数字标识。"; return
                    }
                    if appKey.isEmpty || appKey == OptimizedDictationDefaults.bundled?.appKey { try CredentialStore.delete("dictation.optimized.appKey") }
                    else { try CredentialStore.save("dictation.optimized.appKey", key: appKey) }
                    if token.isEmpty { try CredentialStore.delete("dictation.optimized.token") }
                    else { try CredentialStore.save("dictation.optimized.token", key: token) }
                    model.settings.dictation.optimizedURL = endpoint
                    model.settings.dictation.optimizedAppID = appID
                    model.settings.dictation.optimizedDeviceID = deviceID
                    status = "已保存"
                } catch { status = String(describing: error) }
            }.buttonStyle(SettingsActionStyle())
            Button("使用内置参数") {
                guard let defaults = OptimizedDictationDefaults.bundled else { return }
                endpoint = defaults.url; appID = defaults.appID; deviceID = defaults.deviceID
                appKey = defaults.appKey
                status = "已填入内置参数，保存后生效。"
            }.buttonStyle(SettingsActionStyle())
        }
        .onAppear {
            endpoint = model.settings.dictation.optimizedURL
            appID = model.settings.dictation.optimizedAppID
            deviceID = model.settings.dictation.optimizedDeviceID
            appKey = CredentialStore.load("dictation.optimized.appKey") ?? OptimizedDictationDefaults.bundled?.appKey ?? ""
            token = CredentialStore.load("dictation.optimized.token") ?? ""
        }
        // Saved, filled in or a validation failure: an outcome, one step above the static notes.
        if let status { SettingsNote(status, color: theme.ink2) }
    }
}
