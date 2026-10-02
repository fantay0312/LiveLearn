import SwiftUI

struct TranslationCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandMenu("翻译") {
            if model.settings.modules.isEnabled(.textTranslation) {
            Button("翻译工作台…") { perform("workbench") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("翻译选中文字") { perform("selectTranslate") }
            Button("翻译剪贴板") { perform("pasteboardTranslate") }
            Button("迷你翻译窗") { perform("showMiniWindow") }
            Divider()
            Button("截图翻译…") { perform("snipTranslate") }
            Button("翻译图片…") { TranslationFeature.shared.chooseImage(dark: model.settings.experienceTheme == .stellar) }
            Button("截图识别文字…") { perform("screenshotOCR") }
            Button("静默截图识别…") { perform("silentScreenshotOCR") }
            Button("识别剪贴板图片") { perform("pasteboardOCR") }
            Button("OCR 检查窗口") { perform("showOCRWindow") }
            Divider()
            Button("翻译并替换选区") { perform("translateAndReplace") }
            Button("润色并替换选区") { perform("polishAndReplace") }
            Button("开启 / 关闭自动划词") { perform("toggleAutoSelectText") }
            Divider()
            Button("翻译收藏与历史…") { UnifiedSettingsPresentation.shared.showTranslation(section: 6) }
            Button("将当前译文加入词汇…") { TranslationFeature.shared.reviewCurrentResult(in: model) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("文字翻译设置…") { UnifiedSettingsPresentation.shared.showTranslation() }
            } else {
                Button("添加划词与文字翻译…") { UnifiedSettingsPresentation.shared.showTranslation() }
            }
            Divider()
            Button("浏览器网页翻译…") {
                model.settings.requestedSettingsTab = .browserExtension
                UnifiedSettingsPresentation.shared.open()
            }
        }
    }
    private func perform(_ action: String) {
        TranslationFeature.shared.perform(action, dark: model.settings.experienceTheme == .stellar)
    }

}
