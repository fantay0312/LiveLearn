import SwiftUI
import CaptionDomain
import SessionDomain

/// One lane's caption: a plate holding what is being read, and under it one quiet line for what
/// has not been translated yet or the lane's status. The plate keeps a fixed width and fixed
/// slots, so nothing on it moves when the words change.
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
    /// Unlocked and under the pointer: the plate shows even on a clear caption.
    var grabbable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var reading: CaptionReadingWindow {
        CaptionReadingWindow(current: current, previous: previous, earlier: earlier,
                             capacity: min(28, Double(textWidth) / settings.captionTargetSize * 0.9))
    }
    private var textWidth: CGFloat {
        min(max(140, (readingWidth ?? CGFloat(settings.captionDisplayWidth)) - 2 * Self.platePadding.width),
            max(320, CGFloat(settings.captionTargetSize) * 28))
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
            plate {
                SingleLineCaptionView(content: SingleLineCaptionContent(current: current, previous: previous),
                                      pendingSource: current?.sourceText ?? "",
                                      settings: settings, style: style, statusText: statusText,
                                      label: showsLabel ? label : nil)
            }
        } else { layeredBody }
    }

    /// Round the caption, inside the plate.
    static let platePadding = CGSize(width: 24, height: 14)

    private func plate(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, Self.platePadding.width)
            .padding(.vertical, Self.platePadding.height)
            .frame(maxWidth: .infinity)
            .background {
                let shape = RoundedRectangle(cornerRadius: LLMetrics.Radius.overlay, style: .continuous)
                shape.fill(style.plate(grabbable: grabbable))
                    .overlay { shape.strokeBorder(style.hairline, lineWidth: 1) }
                    .animation(LLMotion.hover(reduceMotion), value: grabbable)
            }
    }

    @ViewBuilder private var layeredBody: some View {
        let reading = self.reading
        VStack(spacing: Self.tailSpacing) {
            plate {
                VStack(alignment: settings.overlayTextAlignment.horizontal, spacing: Self.stackSpacing) {
                    if showsLabel {
                        Text(label).font(LLFont.captionLabel).foregroundStyle(style.label)
                            .lineLimit(1).textRenderer(style.renderer(size: 11))
                    }
                    if settings.showPreviousLine {
                        slot(reading.previous, emphasis: .history)
                    }
                    if let line = reading.current, line.primaryText(showSource: settings.showSourceInOverlay) != nil {
                        stanza(line, emphasis: .current)
                    } else {
                        let waiting = current != nil ? "等待译文" : statusText.isEmpty ? "等待声音" : statusText
                        HStack(spacing: 8) {
                            ListeningMark(color: style.label)
                            if current != nil || statusText != "正在听" {
                                Text(waiting).textRenderer(style.renderer(size: 11))
                            }
                        }
                        .font(LLFont.captionLabel).foregroundStyle(style.label)
                        .frame(height: slotHeight(.current))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(waiting)
                    }
                    if settings.showBreathLine {
                        if let lane {
                            LaneBreathLine(laneID: lane.id, color: style.breath, active: lane.isUploading, weight: .overlay)
                        } else {
                            BreathLine(level: 0, color: style.breath, active: false, weight: .overlay)
                        }
                    }
                }
                .column(textWidth, settings.overlayTextAlignment)
                .transaction { $0.animation = nil }
            }
            // Off the plate: the first words of a sentence nothing has been translated for yet,
            // or the lane's status. Its slot is always kept, so the plate never moves for it.
            ZStack {
                slot(reading.incoming, emphasis: .incoming).accessibilityHidden(true)
                if reading.incoming?.primaryText(showSource: settings.showSourceInOverlay) == nil,
                   !statusText.isEmpty, !RecognitionOrb.replacesStatus(statusText) {
                    Text(statusText).font(LLFont.captionLabel).foregroundStyle(style.label)
                        .textRenderer(style.renderer(size: 11, onPlate: false))
                }
            }
            .column(textWidth, settings.overlayTextAlignment)
            .padding(.horizontal, Self.platePadding.width)
            .transaction { $0.animation = nil }
        }
        .multilineTextAlignment(settings.overlayTextAlignment.text)
    }

    private enum Emphasis { case history, current, incoming }

    private func slotHeight(_ emphasis: Emphasis) -> Double {
        switch emphasis {
        case .current: Self.currentSlotHeight(settings)
        case .history: Self.contextSlotHeight(settings)
        case .incoming: Self.incomingSlotHeight(settings)
        }
    }

    /// Between the lines on the plate.
    static let stackSpacing: Double = 12
    /// Between the plate and the line under it.
    static let tailSpacing: Double = 6

    static func currentSlotHeight(_ settings: AppSettings) -> Double {
        ceil(settings.captionTargetSize * 1.3
             + (settings.showSourceInOverlay ? settings.captionSourceSize * 1.25 + 4 : 0))
    }

    /// The slot kept for the previous sentence: its translation and, when shown, its source.
    static func contextSlotHeight(_ settings: AppSettings) -> Double {
        ceil(settings.captionTargetSize * 0.64 * 1.3
             + (settings.showSourceInOverlay ? settings.captionSourceSize * 0.8 * 1.25 + 4 : 0))
    }

    /// The one line under the plate.
    static func incomingSlotHeight(_ settings: AppSettings) -> Double {
        ceil(settings.captionTargetSize * 0.64 * 1.3)
    }

    /// What the layered block keeps under its plate. 字幕外观's stage reads it to leave that
    /// (there always empty) line out of its preview.
    static func tailHeight(_ settings: AppSettings) -> Double { tailSpacing + incomingSlotHeight(settings) }

    @ViewBuilder private func slot(_ line: CaptionReadingLine?, emphasis: Emphasis) -> some View {
        if let line, line.primaryText(showSource: settings.showSourceInOverlay) != nil {
            stanza(line, emphasis: emphasis)
        } else {
            Color.clear.frame(height: slotHeight(emphasis)).accessibilityHidden(true)
        }
    }

    private func stanza(_ line: CaptionReadingLine, emphasis: Emphasis) -> some View {
        let prominent = emphasis == .current
        let onPlate = emphasis != .incoming
        // Words still in the speaker's language wear the source ink wherever they stand, so the
        // two languages are always told apart by colour.
        let untranslated = line.translation == nil
        let targetSize = settings.captionTargetSize * (prominent ? 1 : emphasis == .history ? 0.62 : 0.70)
        let sourceSize = settings.captionSourceSize * (prominent ? 1 : 0.82)
        let lines = 1
        // The sentence being read keeps one ink from its first word to its last: a translation
        // one revision behind its source is not dimmed, or a live line would pulse with every
        // partial result.
        let alpha = prominent ? 1 : style.secondaryOpacity(emphasis == .history ? 0.6 : 0.68)
        let primary = CaptionReadingWindow.excerpt(line.primaryText(showSource: settings.showSourceInOverlay) ?? "", capacity: Double(textWidth) / targetSize * Double(lines) * 0.90)
        let source = CaptionReadingWindow.excerpt(line.source, capacity: Double(textWidth) / sourceSize * 0.90)
        return VStack(alignment: settings.overlayTextAlignment.horizontal, spacing: prominent ? 6 : 3) {
            Text(primary)
                .font(OverlayTypography.font(settings, size: targetSize, weight: prominent ? style.weight : .medium))
                .foregroundStyle((untranslated ? style.source : style.text).opacity(style.contrastMode == .automatic ? 1 : alpha))
                .lineSpacing(max(2, targetSize * 0.12) * settings.overlayLineSpacing.multiplier)
                .lineLimit(lines).minimumScaleFactor(0.88)
                .textRenderer(style.renderer(source: untranslated, size: targetSize, emphasis: alpha, onPlate: onPlate))
            if settings.showSourceInOverlay, !untranslated, !source.isEmpty, line.source != line.translation {
                Text(source)
                    .font(OverlayTypography.font(settings, size: sourceSize))
                    .foregroundStyle(style.source.opacity(style.contrastMode == .automatic || prominent ? 1 : alpha))
                    .lineLimit(1)
                    .textRenderer(style.renderer(source: true, size: sourceSize, emphasis: prominent ? 1 : alpha, onPlate: onPlate))
            }
        }
        .frame(maxWidth: textWidth, alignment: settings.overlayTextAlignment.frame)
        .frame(height: slotHeight(emphasis))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((line.translation ?? "") + (line.isFinal && settings.showSourceInOverlay ? " " + line.source : ""))
    }
}

private extension View {
    /// The reading column: no wider than `width`, set to the caption's alignment.
    func column(_ width: CGFloat, _ alignment: OverlayTextAlignment) -> some View {
        frame(maxWidth: width, alignment: alignment.frame)
            .frame(maxWidth: .infinity, alignment: alignment.frame)
    }
}
