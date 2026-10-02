// LiveLearn integration; GPL-3.0 with the Easydict translation component.
import SwiftUI
struct PrivacyTab: View {
    var body: some View {
        Form {
            Section("文字与图像") {
                Text("本机 OCR 和本地词典在设备上处理。启用在线翻译、在线 OCR 或云端 AI 后，相应文字或图像会发送到你选择的服务，费用由该服务计收。")
            }
            Section("系统权限") {
                Text("划词可能需要辅助功能或自动化权限；截图需要屏幕录制权限。自动划词沿用 Easydict 配置，可在高级设置中开关并排除指定应用。")
            }
            Section("本机记录") {
                Text("查询历史、收藏和翻译设置独立保存在本机，可在收藏页删除或导出。此模块不启用 Easydict 的 Firebase / Sentry 遥测。")
            }
        }
        .formStyle(TranslationSettingsFormStyle())
    }
}
