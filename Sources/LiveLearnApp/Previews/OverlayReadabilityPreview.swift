import SwiftUI
import CaptionDomain

enum CaptionPreviewScene: String, CaseIterable, Identifiable {
    case light, dark, highContrast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        case .highContrast: "高对比"
        }
    }

    /// Whether the backdrop is bright at `phase`: always on 浅色, never on 深色, and on 高对比 in
    /// alternating stretches, so a played preview crosses from one to the other. What the
    /// caption style is resolved against, and which backdrop colour is drawn.
    func isBright(phase: Double) -> Bool { self == .light || (self == .highContrast && sin(phase * 0.65) >= 0) }
}

/// The preview uses the production LaneBlock, including line wrapping, custom fonts,
/// independent source color, previous-line behavior and accessibility overrides. 字幕外观's
/// stage (`AppearanceCaptionStage`) draws its own scaled, anchored copy from the same parts —
/// the sample sentences, the backdrop and the panel; this one is the fixture renderer's.
struct CaptionPreviewSurface: View {
    let settings: AppSettings
    let scene: CaptionPreviewScene
    var phase: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// The sample: the running fixture's translated sentences, the last as the current one.
    static let segments = SampleData.runningSnapshot(includeGap: false).captions.segments.filter { $0.translation != nil }

    var body: some View {
        let style = OverlayStyle.resolve(settings, forceOpaque: reduceTransparency || settings.overlayOpaque,
                                         increasedContrast: contrast == .increased,
                                         backdropIsBright: scene.isBright(phase: phase))
        block(style: style).padding(16).frame(minHeight: 168)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CaptionPreviewBackdrop(scene: scene, phase: phase) }
    }

    static func layoutWidth(_ width: Double) -> Double { width.isFinite ? min(1400, max(480, width)) : AppSettings.defaultOverlayWidth }

    private func block(style: OverlayStyle) -> some View {
        LaneBlock(lane: nil, current: Self.segments.last, previous: Self.segments.dropLast().last,
                  settings: settings, style: style, statusText: "")
            .captionPanel(style)
    }
}

/// Quiet, neutral preview backgrounds. The contrast scene changes light level without
/// decorative shapes competing with the captions. The dark scene is a neutral #0D0E10: the
/// navy #101419 it replaced echoed the navy ground this app no longer has.
struct CaptionPreviewBackdrop: View {
    let scene: CaptionPreviewScene
    var phase: Double = 0

    var body: some View {
        (scene.isBright(phase: phase) ? Color(hex: 0xF7F7F5) : Color(hex: 0x0D0E10))
            .accessibilityHidden(true)
    }
}

extension View {
    /// The overlay's caption panel — the padding round the block and its fill at the style's
    /// opacity, in the overlay's continuous corners (`OverlayView`) — for the two previews that
    /// draw a caption outside the overlay.
    func captionPanel(_ style: OverlayStyle) -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(style.background.opacity(style.opacity),
                        in: RoundedRectangle(cornerRadius: LLMetrics.Radius.overlay, style: .continuous))
    }
}
