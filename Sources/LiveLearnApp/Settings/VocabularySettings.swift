import SwiftUI

/// Compatibility destination for old settings-tab requests; editing lives in its own window.
struct VocabularySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPage(title: "词汇库", note: "在主界面管理热词和固定译法。") {
            Button("打开词汇库") { model.requestVocabularyWindow() }
                .buttonStyle(TextButtonStyle(flush: true))
        }
    }
}
