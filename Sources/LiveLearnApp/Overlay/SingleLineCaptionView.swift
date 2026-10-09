import AppKit
import SwiftUI
import CaptionDomain
import SessionDomain

struct SingleLineCaptionContent: Equatable, Identifiable {
    let id: String
    let text: String
    /// The sentence `text` translates, shown under it when 显示原文 is on.
    let source: String

    /// One step of a sentence on screen: a translated cue, the stretch of the source under it,
    /// and how long the pair is held before the next.
    struct Step: Hashable {
        let text: String
        let source: String
        let hold: Double
    }

    /// The sentence being spoken once it has a translation; until then the one before it stays.
    init?(current: CaptionSegment?, previous: CaptionSegment?) {
        if let current, let translation = current.translation, !translation.text.isEmpty {
            id = current.id
            text = translation.text
            source = current.sourceText
        } else if let previous, let translation = previous.translation, !translation.text.isEmpty {
            id = previous.id
            text = translation.text
            source = previous.sourceText
        } else { return nil }
    }

    static func lane(from lanes: [LaneStatus], tails: [String: LaneTail]) -> LaneStatus? {
        let recent = lanes.sorted {
            let left = tails[$0.id]?.current
            let right = tails[$1.id]?.current
            if left?.endNs != right?.endNs { return (left?.endNs ?? -1) > (right?.endNs ?? -1) }
            return (left?.order ?? -1) > (right?.order ?? -1)
        }
        return recent.first { lane in
            let tail = tails[lane.id]
            return SingleLineCaptionContent(current: tail?.current, previous: tail?.previous) != nil
        } ?? recent.first
    }

    func cues(width: CGFloat, font: NSFont) -> [String] { Self.cues(text, width: width, font: font) }

    /// The cues with the source under each. A source longer than one line is cut the same way
    /// and walked alongside, so every word of both is shown and neither row ever wraps.
    func steps(width: CGFloat, font: NSFont, sourceFont: NSFont?) -> [Step] {
        let lines = cues(width: width, font: font)
        let under = sourceFont.map { source == text ? [] : Self.cues(source, width: width, font: $0) } ?? []
        guard !lines.isEmpty else { return [] }
        let count = max(lines.count, under.count)
        return (0..<count).map { step in
            let line = lines[step * lines.count / count]
            return Step(text: line, source: under.isEmpty ? "" : under[step * under.count / count],
                        hold: max(1.6, Self.readingDuration(line) * Double(lines.count) / Double(count)))
        }
    }

    static func cues(_ text: String, width: CGFloat, font: NSFont) -> [String] {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let limit = max(font.pointSize * 2, width)
        return CaptionReadingWindow.sentences(flat).flatMap { sentence in
            var remaining = sentence
            var result: [String] = []
            while !remaining.isEmpty {
                var end = remaining.startIndex
                for index in remaining.indices {
                    let next = remaining.index(after: index)
                    let candidate = String(remaining[..<next])
                    if (candidate as NSString).size(withAttributes: [.font: font]).width > limit, end > remaining.startIndex { break }
                    end = next
                }
                if end < remaining.endIndex {
                    let prefix = remaining[..<end]
                    let clause = prefix.lastIndex(where: { "，、,;；:：".contains($0) })
                        .flatMap { prefix.distance(from: prefix.startIndex, to: $0) >= prefix.count / 2 ? $0 : nil }
                    if let boundary = clause ?? prefix.lastIndex(where: \.isWhitespace),
                       prefix.distance(from: prefix.startIndex, to: boundary) >= prefix.count / 2 {
                        end = remaining.index(after: boundary)
                    }
                }
                result.append(String(remaining[..<end]).trimmingCharacters(in: .whitespaces))
                remaining = String(remaining[end...]).trimmingCharacters(in: .whitespaces)
            }
            return result
        }
    }

    static func readingDuration(_ cue: String) -> Double {
        let units = cue.reduce(0.0) { $0 + ($1.isASCII ? 0.5 : 1) }
        return min(4.6, max(1.6, units / 8))
    }
}

/// One translated line at a time, like a video subtitle, with its source on a second, smaller
/// row when 显示原文 is on. Both rows have a fixed height: the block never changes size.
struct SingleLineCaptionView: View {
    let content: SingleLineCaptionContent?
    /// The words of the sentence being spoken, for the source row before anything is translated.
    var pendingSource = ""
    let settings: AppSettings
    let style: OverlayStyle
    let statusText: String
    var label: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label).font(.system(size: 11)).foregroundStyle(style.label)
                    .lineLimit(1).frame(maxWidth: 80).textRenderer(style.renderer(size: 11))
            }
            if let content {
                SingleLineCueText(content: content, settings: settings, style: style, paused: statusText == "已暂停")
                    .id(content.id)
            } else {
                SingleLineRows(text: nil, source: pendingSource, tail: true, settings: settings, style: style,
                               placeholder: statusText.isEmpty || statusText == "正在识别" ? "等待译文" : statusText)
            }
        }
        .frame(height: Self.height(settings))
        .help(statusText)
    }

    static let rowSpacing: CGFloat = 4

    static func lineHeight(fontSize: Double) -> CGFloat { ceil(fontSize * 1.45) }
    static func sourceLineHeight(fontSize: Double) -> CGFloat { ceil(fontSize * 1.3) }

    /// One row, or two with the source.
    static func height(_ settings: AppSettings) -> CGFloat {
        lineHeight(fontSize: settings.captionTargetSize)
            + (settings.showSourceInOverlay ? rowSpacing + sourceLineHeight(fontSize: settings.captionSourceSize) : 0)
    }
}

/// The translated row over the source row, each one line in its own fixed height.
private struct SingleLineRows: View {
    /// nil shows `placeholder` in the label style instead of a cue.
    let text: String?
    let source: String
    /// Keep the newest words of a source longer than the row (it is still being spoken).
    var tail = false
    let settings: AppSettings
    let style: OverlayStyle
    var placeholder = ""

    var body: some View {
        let alignment: Alignment = settings.overlayTextAlignment == .center ? .center : .leading
        VStack(spacing: SingleLineCaptionView.rowSpacing) {
            Group {
                if let text {
                    Text(text)
                        .font(OverlayTypography.font(settings, size: settings.captionTargetSize, weight: style.weight))
                        .foregroundStyle(style.text).lineLimit(1)
                        .textRenderer(style.renderer(size: settings.captionTargetSize))
                } else {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(style.label).lineLimit(1)
                        .textRenderer(style.renderer(size: 13))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .frame(height: SingleLineCaptionView.lineHeight(fontSize: settings.captionTargetSize))
            if settings.showSourceInOverlay {
                GeometryReader { geometry in
                    let font = OverlayTypography.nativeFont(family: settings.overlayFontFamily, size: settings.captionSourceSize, weight: .regular)
                    let shown = tail ? SingleLineCaptionContent.cues(source, width: max(1, geometry.size.width), font: font).last ?? "" : source
                    Text(shown)
                        .font(Font(font)).foregroundStyle(style.source).lineLimit(1)
                        .textRenderer(style.renderer(source: true, size: settings.captionSourceSize))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
                }
                .frame(height: SingleLineCaptionView.sourceLineHeight(fontSize: settings.captionSourceSize))
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct SingleLineCueText: View {
    let content: SingleLineCaptionContent
    let settings: AppSettings
    let style: OverlayStyle
    let paused: Bool
    @Environment(\.staticRender) private var staticRender
    @State private var stepIndex = 0
    @State private var visibleSince = ContinuousClock.now

    private struct StepKey: Hashable {
        let steps: [SingleLineCaptionContent.Step]
        let stationary: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let font = OverlayTypography.nativeFont(family: settings.overlayFontFamily, size: settings.captionTargetSize, weight: style.weight)
            let sourceFont = settings.showSourceInOverlay
                ? OverlayTypography.nativeFont(family: settings.overlayFontFamily, size: settings.captionSourceSize, weight: .regular) : nil
            let steps = content.steps(width: width, font: font, sourceFont: sourceFont)
            let step = steps.isEmpty ? nil : steps[min(stepIndex, steps.count - 1)]
            SingleLineRows(text: step?.text ?? "", source: step?.source ?? "", settings: settings, style: style)
                .frame(width: width, height: geometry.size.height)
                .task(id: StepKey(steps: steps, stationary: staticRender || paused)) {
                    guard !steps.isEmpty else { return }
                    stepIndex = min(stepIndex, steps.count - 1)
                    guard !staticRender, !paused else { visibleSince = .now; return }
                    while stepIndex < steps.count - 1 {
                        let deadline = visibleSince.advanced(by: .seconds(steps[stepIndex].hold))
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                        guard !Task.isCancelled else { return }
                        stepIndex += 1
                        visibleSince = .now
                    }
                }
        }
        .clipped()
    }
}
