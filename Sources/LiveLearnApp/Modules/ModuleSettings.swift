import SwiftUI

struct ModuleSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        SettingsPage(title: "只留下你需要的", note: "实时翻译始终在这里。其他能力，想用时再添加。") {
            SettingsGroup("已随应用提供") {
                SettingRow("实时翻译", note: "电脑声音与麦克风 · 双语字幕 · 会话与词汇") {
                    SettingValue("核心功能")
                }
            }
            ForEach(OptionalModule.allCases) { module in
                SettingsGroup(module.title) { ModuleInstallControl(module: module) }
            }
            SettingsNote("模块下载到此 Mac 的应用支持目录。卸载模块保留你的设置、词汇与服务凭据；浏览器中已加载的扩展需在浏览器内移除。")
            Button("重新看看使用引导") {
                UnifiedSettingsPresentation.shared.dismiss()
                model.settings.onboardingCompleted = false
            }.buttonStyle(SettingsActionStyle())
        }
    }
}

struct ModuleInstallControl: View {
    let module: OptionalModule
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    private var library: ModuleLibrary { model.settings.modules }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(module.detail).font(LLFont.body).foregroundStyle(theme.ink2)
            if let status = library.activity[module] {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(status).font(LLFont.body).foregroundStyle(theme.ink2)
                    Spacer()
                    Button("取消") { library.cancel(module) }.buttonStyle(SettingsActionStyle())
                }
            } else if let artifact = library.installed[module] {
                HStack(spacing: 20) {
                    Text(library.isEnabled(module) ? "已安装 · \(artifact.version)" : "已停用 · \(artifact.version)")
                        .font(LLFont.label).foregroundStyle(theme.ink3)
                    Spacer()
                    Button(library.isEnabled(module) ? "停用" : "启用") {
                        if module == .textTranslation { TranslationFeature.shared.shutdown() }
                        if module == .dictation { model.dictation.cancel(hide: true, immediately: true) }
                        library.setEnabled(module, !library.isEnabled(module))
                    }.buttonStyle(SettingsActionStyle())
                    Button("卸载") {
                        if module == .textTranslation { TranslationFeature.shared.shutdown() }
                        if module == .dictation { model.dictation.cancel(hide: true, immediately: true) }
                        library.remove(module)
                    }.buttonStyle(SettingsActionStyle())
                        .disabled(module == .textTranslation && TranslationSettingsComponent.shared.requiresRestartToUnload)
                }.disabled(model.isActive || model.dictation.isActive)
                if module == .textTranslation && TranslationSettingsComponent.shared.requiresRestartToUnload {
                    SettingsNote("本次已打开文字翻译设置；如需卸载，请先停用并重新启动 LiveLearn，再回到这里。")
                }
            } else {
                HStack {
                    Text("未安装").font(LLFont.label).foregroundStyle(theme.ink3)
                    Spacer()
                    Button("下载并安装") { library.install(module) }.buttonStyle(SettingsActionStyle())
                }
            }
            if let error = library.errors[module] { SettingsNote(error, color: theme.brick) }
            if module == .browserExtension, library.isEnabled(module) {
                SettingsNote("文件已下载；请在「网页翻译」中准备文件并加载到浏览器。")
            }
        }.padding(.vertical, 8)
    }
}

struct ModuleMissingView: View {
    let module: OptionalModule
    var body: some View {
        SettingsPage(title: module.title, note: "这是一项可选能力，默认不会安装。") {
            ModuleInstallControl(module: module)
            SettingsNote("不安装也可以正常使用实时翻译。以后随时可以在功能管理中更改。")
        }
    }
}
