import SwiftUI
import CaptionDomain
import SessionDomain

struct LaneBlock: View {
    let lane: LaneStatus?
    let current: CaptionSegment?
    let previous: CaptionSegment?
    let settings: AppSettings
    let style: OverlayStyle
    let statusText: String
    var showsLabel = false
    var earlier: CaptionSegment? = nil
    var readingWidth: CGFloat? = nil

    private var reading: CaptionReadingWindow {
        CaptionReadingWindow(current: current, previous: previous, earlier: earlier,
                             capacity: min(28, Double(textWidth) / settings.captionTargetSize * 0.9))
    }
    private var textWidth: CGFloat {
        min(max(140, (readingWidth ?? CGFloat(settings.captionDisplayWidth)) - 48), max(320, CGFloat(settings.captionTargetSize) * 28))
    }

    private var label: String {
        guard let lane else { return "LiveLearn" }
        switch lane.configuration.source.kind {
        case .microphone: return "麦克风 · 我"
        case .application: return "应用 · \(lane.configuration.source.displayName)"
        case .system: return "系统声"
        }
    }

    var body: some View {
        if settings.captionPresentation == .singleLine {
            SingleLineCaptionView(content: SingleLineCaptionContent(current: current, previous: previous),
                                  settings: settings, style: style, statusText: statusText,
                                  label: showsLabel ? label : nil)
        } else { layeredBody }
    }

    @ViewBuilder private var layeredBody: some View {
        let reading = self.reading
        VStack(alignment: settings.overlayTextAlignment.horizontal, spacing: Self.stackSpacing) {
            if showsLabel {
                Text(label).font(LLFont.captionLabel).foregroundStyle(style.source)
                    .lineLimit(1).textRenderer(style.renderer(source: true, size: 11))
            }
            if settings.showPreviousLine {
                slot(reading.previous, emphasis: .history)
            }
            if let line = reading.current, line.primaryText(showSource: settings.showSourceInOverlay) != nil {
                stanza(line, emphasis: .current)
            } else {
                HStack(spacing: 8) {
                    ListeningMark(color: style.source)
                    if current != nil { Text("等待译文") }
                    else if statusText != "正在听" { Text(statusText.isEmpty ? "等待声音" : statusText) }
                }
                .font(LLFont.captionLabel).foregroundStyle(style.source)
                .frame(height: slotHeight(.current))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(current != nil ? "等待译文" : statusText.isEmpty ? "等待声音" : statusText)
            }
            ZStack {
                slot(reading.incoming, emphasis: .incoming).accessibilityHidden(true)
                if reading.incoming?.primaryText(showSource: settings.showSourceInOverlay) == nil,
                   !statusText.isEmpty, !RecognitionOrb.replacesStatus(statusText) {
                    Text(statusText).font(.system(size: 11)).foregroundStyle(style.source.opacity(0.6))
                }
            }
            if settings.showBreathLine {
                if let lane {
                    LaneBreathLine(laneID: lane.id, color: style.breath, active: lane.isUploading, weight: .overlay)
                } else {
                    BreathLine(level: 0, color: style.breath, active: false, weight: .overlay)
                }
            }
        }
        .frame(maxWidth: textWidth, alignment: settings.overlayTextAlignment.frame)
        .frame(maxWidth: .infinity, alignment: settings.overlayTextAlignment.frame)
        .multilineTextAlignment(settings.overlayTextAlignment.text)
        .transaction { $0.animation = nil }
    }

    private enum Emphasis { case history, current, incoming }

    private func slotHeight(_ emphasis: Emphasis) -> Double {
        emphasis == .current ? Self.currentSlotHeight(settings) : Self.incomingSlotHeight(settings)
    }

    /// Between the layered block's lines. 字幕外观's stage reads it with the incoming slot.
    static let stackSpacing: Double = 12

    static func currentSlotHeight(_ settings: AppSettings) -> Double {
        ceil(settings.captionTargetSize * 1.3
             + (settings.showSourceInOverlay ? settings.captionSourceSize * 1.25 + 4 : 0))
    }

    /// The slot kept for the previous and the incoming line. 字幕外观's stage reads it to leave
    /// the (always empty) incoming slot out of its preview.
    static func incomingSlotHeight(_ settings: AppSettings) -> Double {
        ceil(settings.captionTargetSize * 0.64 * 1.3
             + (settings.showSourceInOverlay ? settings.captionSourceSize * 0.8 * 1.25 + 4 : 0))
    }

    @ViewBuilder private func slot(_ line: CaptionReadingLine?, emphasis: Emphasis) -> some View {
        if let line, line.primaryText(showSource: settings.showSourceInOverlay) != nil {
            stanza(line, emphasis: emphasis)
        } else {
            Color.clear.frame(height: slotHeight(emphasis)).accessibilityHidden(true)
        }
    }

    private func stanza(_ line: CaptionReadingLine, emphasis: Emphasis) -> some View {
        let prominent = emphasis == .current
        let targetSize = settings.captionTargetSize * (prominent ? 1 : emphasis == .history ? 0.62 : 0.70)
        let sourceSize = settings.captionSourceSize * (prominent ? 1 : 0.82)
        let lines = 1
        let alpha = prominent ? (line.isStale ? style.secondaryOpacity(0.70) : 1) : style.secondaryOpacity(emphasis == .history ? 0.48 : 0.68)
        let primary = CaptionReadingWindow.excerpt(line.primaryText(showSource: settings.showSourceInOverlay) ?? "", capacity: Double(textWidth) / targetSize * Double(lines) * 0.90)
        let source = CaptionReadingWindow.excerpt(line.source, capacity: Double(textWidth) / sourceSize * 0.90)
        return VStack(alignment: settings.overlayTextAlignment.horizontal, spacing: prominent ? 6 : 3) {
            Text(primary)
                .font(OverlayTypography.font(settings, size: targetSize, weight: prominent ? style.weight : .medium))
                .foregroundStyle(style.text.opacity(style.contrastMode == .automatic ? 1 : alpha))
                .lineSpacing(max(2, targetSize * 0.12) * settings.overlayLineSpacing.multiplier)
                .lineLimit(lines).minimumScaleFactor(0.88)
                .textRenderer(style.renderer(size: targetSize, emphasis: alpha))
            if settings.showSourceInOverlay, line.translation != nil, !source.isEmpty, line.source != line.translation {
                Text(source)
                    .font(OverlayTypography.font(settings, size: sourceSize))
                    .foregroundStyle(style.source.opacity(style.contrastMode == .automatic || prominent ? 1 : alpha))
                    .lineLimit(1)
                    .textRenderer(style.renderer(source: true, size: sourceSize, emphasis: prominent ? 1 : alpha))
            }
        }
        .frame(maxWidth: textWidth, alignment: settings.overlayTextAlignment.frame)
        .frame(height: slotHeight(emphasis))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((line.translation ?? "") + (line.isFinal && settings.showSourceInOverlay ? " " + line.source : ""))
    }
}
