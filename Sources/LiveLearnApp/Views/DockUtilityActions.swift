import SwiftUI

struct DockUtilityActions: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            if ModuleLibrary.shared.isEnabled(.textTranslation) {
            Button {
                TranslationFeature.shared.perform("workbench", dark: theme.isDark)
            } label: {
                HStack(spacing: 7) {
                    if TranslationFeature.shared.openingActions.contains("workbench") {
                        ProgressView().controlSize(.mini)
                    } else {
                        DockUtilityIcon(kind: .translation)
                    }
                    Text(TranslationFeature.shared.openingActions.contains("workbench") ? "正在打开" : "翻译")
                }
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 90, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DockButtonStyle(utility: true)).accessibilityLabel("翻译工作台")
            .disabled(TranslationFeature.shared.openingActions.contains("workbench"))
            .accessibilityValue(TranslationFeature.shared.openingActions.contains("workbench") ? "正在打开" : "")
            .help("文本翻译、划词、截图识别与词典 · ⌘⇧T")
            }
            Spacer()
            Button { UnifiedSettingsPresentation.shared.open() } label: {
                DockUtilityIcon(kind: .settings).font(.system(size: 15))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DockButtonStyle(utility: true)).accessibilityLabel("设置").help("设置 · ⌘,")
        }
    }
}
