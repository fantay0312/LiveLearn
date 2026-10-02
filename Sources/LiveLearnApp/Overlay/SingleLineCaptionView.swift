import AppKit
import SwiftUI
import CaptionDomain
import SessionDomain

struct SingleLineCaptionContent: Equatable, Identifiable {
    let id: String
    let text: String
    let isStale: Bool

    init?(current: CaptionSegment?, previous: CaptionSegment?) {
        if let current, let translation = current.translation, !translation.text.isEmpty {
            id = current.id
            text = translation.text
            isStale = translation.isStale
        } else if let previous, let translation = previous.translation, !translation.text.isEmpty {
            id = previous.id
            text = translation.text
            isStale = true
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

    func cues(width: CGFloat, font: NSFont) -> [String] {
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

struct SingleLineCaptionView: View {
    let content: SingleLineCaptionContent?
    let settings: AppSettings
    let style: OverlayStyle
    let statusText: String
    var label: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label).font(.system(size: 11)).foregroundStyle(style.source)
                    .lineLimit(1).frame(maxWidth: 80)
            }
            if let content {
                SingleLineCueText(content: content, settings: settings, style: style, paused: statusText == "已暂停")
                    .id(content.id)
            } else {
                Text(statusText.isEmpty || statusText == "正在识别" ? "等待译文" : statusText)
                    .font(.system(size: 13)).foregroundStyle(style.source)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Self.lineHeight(fontSize: settings.captionTargetSize))
        .help(statusText)
    }

    static func lineHeight(fontSize: Double) -> CGFloat { ceil(fontSize * 1.45) }
}

private struct SingleLineCueText: View {
    let content: SingleLineCaptionContent
    let settings: AppSettings
    let style: OverlayStyle
    let paused: Bool
    @Environment(\.staticRender) private var staticRender
    @State private var cueIndex = 0
    @State private var visibleSince = ContinuousClock.now

    private struct CueKey: Hashable {
        let cues: [String]
        let stationary: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let font = OverlayTypography.nativeFont(family: settings.overlayFontFamily, size: settings.captionTargetSize, weight: style.weight)
            let cues = content.cues(width: width, font: font)
            let text = cues.isEmpty ? "" : cues[min(cueIndex, cues.count - 1)]
            let emphasis = content.isStale ? style.secondaryOpacity(0.7) : 1
            Text(text)
                .font(Font(font)).lineLimit(1)
                .foregroundStyle(style.text.opacity(style.contrastMode == .automatic ? 1 : emphasis))
                .textRenderer(style.renderer(size: settings.captionTargetSize, emphasis: emphasis))
                .frame(width: width, height: geometry.size.height,
                       alignment: settings.overlayTextAlignment == .center ? .center : .leading)
                .transaction { $0.animation = nil }
                .task(id: CueKey(cues: cues, stationary: staticRender || paused)) {
                    guard !cues.isEmpty else { return }
                    cueIndex = min(cueIndex, cues.count - 1)
                    guard !staticRender, !paused else { visibleSince = .now; return }
                    while cueIndex < cues.count - 1 {
                        let deadline = visibleSince.advanced(by: .seconds(SingleLineCaptionContent.readingDuration(cues[cueIndex])))
                        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                        guard !Task.isCancelled else { return }
                        cueIndex += 1
                        visibleSince = .now
                    }
                }
        }
        .clipped()
    }
}
