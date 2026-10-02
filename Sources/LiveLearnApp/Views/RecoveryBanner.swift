import SwiftUI

/// What is wrong, what to do, and the one action that does it (§8: state text says what is
/// true). Used above the transcript and on Home (a start blocker, a failed session, a running
/// session's advice). Bare on the ground, like every in-window structure: no card, no padding of
/// its own — the page places it (the transcript insets it to its text column). The only color
/// is the title in `brick`; the action is a text word.
struct RecoveryBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    let advice: RecoveryAdvice
    /// Home's variant, centred on Home's one axis. It lives in the air under the routes, which
    /// at the minimum window holds little more than a line, so the way out comes first: the
    /// action on the title's line (`需要系统音频录制权限 · 打开系统录音权限设置`), the line only
    /// as tall as its text — the action's 28 pt target hangs over it — then the whole detail,
    /// which may be an engine's or a capture's own error text and is never cut (the page
    /// scrolls). The transcript's is set on its text column, detail before action.
    var compact = false

    var body: some View {
        if compact {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(advice.title).font(LLFont.bodyStrong).foregroundStyle(theme.brick)
                    if let action = advice.action {
                        Text("·").font(LLFont.body).foregroundStyle(HomeInk(theme).quiet).accessibilityHidden(true)
                        Button(action.label) { model.perform(action) }
                            .buttonStyle(TextButtonStyle(tint: theme.ink, flush: true))
                            // The flush style's target reaches 6 pt past its 28 pt frame; held to the
                            // frame, it overhangs the 16 pt line by 6 pt a side and takes no click or
                            // hover from the route above or the detail below.
                            .contentShape(Rectangle())
                            .padding(.vertical, -6)
                    }
                }
                Text(advice.detail)
                    .font(LLFont.label)
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.ink2)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                Text(advice.title)
                    .font(LLFont.bodyStrong)
                    .foregroundStyle(theme.brick)
                Text(advice.detail)
                    .font(LLFont.body)
                    .lineSpacing(LLLeading.body)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = advice.action {
                    Button(action.label) { model.perform(action) }
                        .buttonStyle(TextButtonStyle(flush: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
