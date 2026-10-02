import AppKit
import SwiftUI

struct CaptionAutoContrastPermission: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var hasAccess = CaptionBackdropSampler.hasAccess
    @State private var requested = false

    var body: some View {
        if model.settings.overlayContrastMode == .automatic && !hasAccess {
            VStack(alignment: .leading, spacing: 8) {
                Text("自动切换字色需要屏幕录制权限，只在本机计算字幕下方的画面明暗。")
                    .font(LLFont.label).foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(requested ? "打开屏幕录制设置" : "允许识别画面明暗") {
                    if requested {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    } else {
                        hasAccess = CGRequestScreenCaptureAccess()
                        requested = true
                    }
                }.buttonStyle(TextButtonStyle(flush: true))
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                hasAccess = CaptionBackdropSampler.hasAccess
            }
        }
    }
}
