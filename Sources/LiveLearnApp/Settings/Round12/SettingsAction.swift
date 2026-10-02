import SwiftUI

/// The one action grammar of a settings page (round 12): a word, 13/500 in `ink`, at the row's
/// rag.
///
/// Settings had two: graphite slabs (重新检查, 听 3 秒, 导出, 保存) and bare
/// words (`TextButtonStyle` — 打开本地模型, 下载). A slab is a lifted surface on a ground whose
/// light comes only from points, so every settings action is now a word. It rests in full `ink`
/// and one step more weight, so the page's ladder reads: row name `ink`/400, menu value `ink`
/// with an `ink3` chevron, action `ink`/500, fact `ink2`/400, note `ink3`/400. Colour and weight
/// together tell 打开本地模型 (something to press) from 免费 (something to read) at the same rag —
/// at the shared text action's `ink2` rest, the weight alone did, and under the step sentences
/// of 网页翻译 the actions read as a fourth instruction. So this does not use `actionInk`: text
/// actions elsewhere keep their `ink2` → `ink`. A semantic tint (brick, for 删除) keeps its
/// colour; disabled is one token.
///
/// A word already at `ink` cannot brighten, so the pointer answers with the settings' own
/// transient light (`SettingsInteractionLight`, as the rail rows and the segment words) — the
/// way `SettingsBareMenu`'s value, also at rest in `ink`, answers with its chevron. That light is
/// the neutral `ink` one even on a tinted word: it says where the pointer is, and every other
/// one (rail rows, segment words, menu values) is ink, so a brick haze under 删除 would be the
/// one coloured light.
///
/// Flush: no side padding, so the word's own edge sits on the rag with the values above and
/// below it. The target is the 28 pt control height with a 6 pt margin round it, but only the
/// word's own line counts in layout (`targetOverhang` above and below, as `QuietSwitchStyle`
/// does with its capsule): a row with an action is then as tall as a row with a value — 13 pt
/// text and 12 pt above and below — where the 28 pt used to make it 52 pt against 40. Press is
/// the settings press (0.96 and 1 pt down, `ControlPressFeedback`) at 55 %.
struct SettingsActionStyle: ButtonStyle {
    /// What the 28 pt control height reaches past a 13 pt line (16 pt) above and below.
    static let targetOverhang: CGFloat = 6

    /// A semantic colour (brick for a destructive action) instead of `ink`.
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, tint: tint)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let tint: Color?
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var ink: Color { enabled ? tint ?? theme.ink : theme.inkDisabled }

        var body: some View {
            let pressed = enabled && configuration.isPressed
            configuration.label
                .font(LLFont.bodyStrong)
                .foregroundStyle(ink)
                .lineLimit(1)
                .frame(height: LLMetrics.controlHeight)
                // 10 pt past the word each side, as a segment word's padded frame carries it: on
                // the flush word's own box the light would fade out under the glyphs.
                .background {
                    SettingsInteractionLight(color: theme.ink, active: pressed || (enabled && hovering), pressed: pressed)
                        .padding(.horizontal, -10)
                }
                .opacity(configuration.isPressed && enabled ? 0.55 : 1)
                .contentShape(Rectangle().inset(by: -6))
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous).inset(by: -6))
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
                .padding(.vertical, -SettingsActionStyle.targetOverhang)
        }
    }
}
