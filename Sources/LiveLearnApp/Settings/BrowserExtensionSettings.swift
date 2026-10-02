import SwiftUI

/// 设置 › 网页翻译. Round 12: the page speaks the settings grammar end to end — the extension is
/// a row with its version as a fact (it opened with a small product card: a 15/500 name, a
/// version corner and a tagline), the three loading steps are a labelled group with `ink3`
/// numerals rather than a free block with blue ones, and every action is a word.
struct BrowserExtensionSettings: View {
    @Environment(\.theme) private var theme
    @State private var installer = BrowserExtensionInstaller()
    @State private var browser = TranslationBrowser.allCases.first { $0.applicationURL != nil } ?? .chrome

    var body: some View {
        SettingsPage(title: "网页翻译", note: "让双语阅读留在正在浏览的页面。") {
            SettingsGroup("扩展", note: "扩展已单独下载，接下来将它加载到浏览器。") {
                SettingRow("LiveLearn", note: "全文对照 · 划词翻译 · 输入框翻译") {
                    SettingValue(installer.package?.version ?? "未打包")
                }
            }
            SettingsGroup("安装到浏览器") {
                SettingRow("浏览器") {
                    PaperMenu(title: browser.name + (browser.applicationURL == nil ? "（未安装）" : ""), font: LLFont.body, color: theme.ink, help: "浏览器") {
                        TranslationBrowser.allCases.map { item in
                            .row(item.name, id: item.rawValue, detail: item.applicationURL == nil ? "未安装" : nil,
                                 selected: browser == item) { browser = item }
                        }
                    }
                }
                SheetDivider()
                SettingRow("本地文件", note: installer.needsUpdate ? "文件需要更新或修复；已有浏览器配置会保留。" : installer.prepared ? "已准备；浏览器是否启用请在扩展管理页确认。" : "保存在此 Mac 的 LiveLearn 应用支持目录。") {
                    Button(installer.isPreparing ? "正在准备…" : installer.prepared || installer.needsUpdate ? "更新 / 修复文件" : "准备本地扩展") {
                        Task { await installer.prepare() }
                    }
                    .buttonStyle(SettingsActionStyle())
                    .disabled(installer.isPreparing || installer.package == nil)
                }
            }
            SettingsGroup("加载扩展") {
                VStack(alignment: .leading, spacing: LLMetrics.space(3)) {
                    instruction("1", "准备扩展后，打开浏览器的扩展管理页。")
                    instruction("2", "开启「开发者模式」，选择「加载已解压的扩展程序」。")
                    instruction("3", "选择 LiveLearn 扩展文件夹，再将扩展固定到工具栏。")
                    // Under the steps' text, not under their numerals: the actions carry out
                    // the sentences above them.
                    HStack(spacing: LLMetrics.space(5)) {
                        Button("打开扩展管理") { installer.openManager(browser) }.buttonStyle(SettingsActionStyle())
                            .disabled(!installer.prepared || browser.applicationURL == nil)
                        Button("显示文件夹") { installer.reveal() }.buttonStyle(SettingsActionStyle())
                            .disabled(!installer.prepared)
                        Button("复制路径") { installer.copyPath() }.buttonStyle(SettingsActionStyle())
                            .disabled(!installer.prepared)
                    }
                    .padding(.leading, Self.numeralColumn + LLMetrics.space(3))
                    if let message = installer.message { SettingsNote(message, color: theme.ink2) }
                    if let error = installer.error { SettingsNote(error, color: theme.brick) }
                    if installer.package == nil { SettingsNote("扩展文件缺失，请在功能管理中重新安装。", color: theme.brick) }
                }
                .padding(.vertical, LLMetrics.space(3))
            }
            SettingsGroup("开始阅读", note: "打开网页，点击扩展的翻译按钮。网页选中文字后，也可右键交给 LiveLearn 翻译工作台。") {
                SettingRow("语言与翻译服务", note: "扩展启用后，在这里选择目标语言和服务。") {
                    Button("扩展设置") { installer.openOptions(browser) }.buttonStyle(SettingsActionStyle())
                        .disabled(!installer.prepared || browser.applicationURL == nil)
                }
            }
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                SettingsNote("默认网页翻译使用 Microsoft 在线服务；选择云端服务会发送待译文字，并可能产生服务费用。可在扩展设置中配置 Ollama 等本地服务，配置独立于字幕引擎。")
                SettingsNote("当前支持 Chrome、Edge、Brave、Arc 和 Chromium。Safari 与 Firefox 的正式安装需要各自的签名包，本地加载入口暂不包含它们。")
                Button("查看开源许可与对应源码") { installer.showSource() }
                    .buttonStyle(SettingsActionStyle()).disabled(installer.package == nil)
            }
        }
    }

    /// The numerals' column: a digit and its air, so the step sentences share one left edge.
    private static let numeralColumn: CGFloat = 18

    /// A numbered step: the numeral a 13 pt monospaced `ink3` digit (it was the palette's one
    /// sky-blue, at an off-scale 12 pt), the sentence 13 pt `ink2`.
    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LLMetrics.space(3)) {
            Text(number).font(LLFont.body.monospacedDigit()).foregroundStyle(theme.ink3)
                .frame(width: Self.numeralColumn, alignment: .leading)
            Text(text).font(LLFont.body).foregroundStyle(theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
