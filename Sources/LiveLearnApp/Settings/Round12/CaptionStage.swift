import SwiftUI
import CaptionDomain

/// 字幕外观's stage (round 12): the live caption the page's controls change, drawn with the
/// production `LaneBlock` at the overlay's real width and scaled to fit, between a row of scene
/// words with 播放 and a line of facts. The two lines of words stand on the page's column, as
/// every other line on the page does; only the picture between them breaks out of it, by
/// `breakout` either side (`AppearanceSettings.stageBreakout`), so the page keeps one left and
/// one right edge and the picture is a figure centred on them.
///
/// What changed from the preview it replaced (round 11's `OverlayReadabilityPreview`): the
/// dark scene is a neutral #0D0E10 instead of a navy #101419 (a small echo of the rejected navy
/// ground; `CaptionPreviewBackdrop`, which the stage and the fixture renders share, now draws
/// it); the caption stands where the overlay stands — its block anchored 20 pt from the
/// stage's bottom, or its top when 默认位置 is 顶部 — and without the empty slot the overlay keeps
/// under the sentence for a line that has not arrived, which only pushed the sentence into the
/// upper half; the stage is 10 pt round like the app's other sheets (it was an off-scale 8);
/// 播放 is a word, not a glyph and a word; and the facts are `ink3`, one step under the caption
/// they describe.
///
/// Playing is a 24 fps `TimelineView` that only runs while 播放 is on and the page is shown —
/// never under Reduce Motion or in an offscreen render, where the stage is the still frame.
struct AppearanceCaptionStage: View {
    /// How far the picture reaches past the column on each side.
    var breakout: CGFloat = 0
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    @Environment(\.theme) private var theme
    @State private var scene: CaptionPreviewScene = .dark
    @State private var playing = false

    static let height: CGFloat = 148

    var body: some View {
        VStack(spacing: LLMetrics.space(2)) {
            HStack(alignment: .firstTextBaseline) {
                TextSegment(options: CaptionPreviewScene.allCases.map { ($0, $0.label) },
                            selection: $scene, label: "预览画面")
                Spacer()
                Button(playing ? "暂停" : "播放") { playing.toggle() }
                    .buttonStyle(SettingsActionStyle())
                    .disabled(reduceMotion)
                    .help(reduceMotion ? "系统已开启减少动态效果，使用静态预览" : "播放模拟视频画面，检查字幕可读性")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing || reduceMotion || staticRender)) { timeline in
                CaptionStageSurface(settings: model.settings, scene: scene,
                                    phase: playing && !reduceMotion && !staticRender ? timeline.date.timeIntervalSinceReferenceDate : 0)
            }
            .frame(height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: LLMetrics.Radius.card, style: .continuous))
            // Wider than the column it is laid out in, which keeps its frame.
            .padding(.horizontal, -breakout)
            HStack {
                Text("实时预览 · 按实际宽度缩放")
                Spacer()
                Text("\(Int(model.settings.captionTargetSize)) pt · \(Int(model.settings.captionDisplayWidth)) pt 宽")
                    .monospacedDigit()
            }
            .font(LLFont.label).foregroundStyle(theme.ink3)
        }
    }
}

/// The stage itself: the backdrop of the chosen scene and the caption block anchored where the
/// overlay sits, `inset` in from that edge. The block is laid out at the overlay's width (the
/// same `layoutWidth` clamp as `CaptionPreviewSurface`) and scaled down to fit both ways — never
/// up — so wrapping, fonts, colours and the previous line are exactly the overlay's. Sample,
/// backdrop and panel are `CaptionPreviewSurface`'s own, so the two previews cannot drift apart.
private struct CaptionStageSurface: View {
    let settings: AppSettings
    let scene: CaptionPreviewScene
    var phase: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// From the anchored edge to the block, and the least air on the other three sides.
    private static let inset: CGFloat = 20

    /// The layered block's empty tail: the slot `LaneBlock` keeps under the current sentence for
    /// the next line, and the stack spacing before it. The stage's sentence is final and
    /// has no status text, so that slot is always empty here; the stage leaves it out (see
    /// `block`). Under the breath line the slot sits between sentence and line, so it stays.
    static func emptyTail(_ settings: AppSettings) -> CGFloat {
        guard settings.captionPresentation == .layered, !settings.showBreathLine else { return 0 }
        return LaneBlock.stackSpacing + LaneBlock.incomingSlotHeight(settings)
    }

    var body: some View {
        let style = OverlayStyle.resolve(settings, forceOpaque: reduceTransparency || settings.overlayOpaque,
                                         increasedContrast: contrast == .increased,
                                         backdropIsBright: scene.isBright(phase: phase))
        let top = settings.overlayPlacement == .top
        GeometryReader { proxy in
            let width = CGFloat(CaptionPreviewSurface.layoutWidth(settings.captionDisplayWidth))
            let available = proxy.size
            let inset = Self.inset
            block(style: style)
                .frame(width: width).fixedSize(horizontal: false, vertical: true)
                // Scale to fit, then move the scaled block from the centre to its edge; both
                // read the block's own height, which only exists at this point.
                .visualEffect { content, geometry in
                    let scale = min(1, (available.width - 2 * inset) / width,
                                    (available.height - 2 * inset) / max(1, geometry.size.height))
                    let half = scale * geometry.size.height / 2
                    let y = top ? inset + half : available.height - inset - half
                    return content.scaleEffect(scale).offset(y: y - available.height / 2)
                }
                .position(x: available.width / 2, y: available.height / 2)
        }
        .background { CaptionPreviewBackdrop(scene: scene, phase: phase) }
        .clipped()
    }

    /// The overlay's block with its empty tail taken out of the layout (it is clear, so nothing
    /// that draws is lost): the panel's padding and fill close under the sentence, and the
    /// anchoring above lands the sentence itself 20 pt off the stage's edge.
    private func block(style: OverlayStyle) -> some View {
        let segments = CaptionPreviewSurface.segments
        return LaneBlock(lane: nil, current: segments.last, previous: segments.dropLast().last,
                         settings: settings, style: style, statusText: "")
            .padding(.bottom, -Self.emptyTail(settings))
            .captionPanel(style)
    }
}
