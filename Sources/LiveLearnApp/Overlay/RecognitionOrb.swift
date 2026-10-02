import SwiftUI
import ThinkingOrbsKit

/// Libraries.dev's composing/ribbon orb, with the original small-size tuning. Text-free
/// on screen; the status stays available to VoiceOver. Only recognition mounts a clock.
struct RecognitionOrb: View {
    let lightInk: Bool
    var frozenTime: Double? = nil
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        ThinkingOrb(state: .composing, size: .px64, theme: lightInk ? .dark : .light,
                    paused: staticRender, displaySize: 32)
            .orbFrozenTime(frozenTime ?? (staticRender ? 0.6 : nil))
            .accessibilityLabel("识别中")
            .help("识别中")
    }

    static func replacesStatus(_ status: String) -> Bool { status == "识别中" }
}
