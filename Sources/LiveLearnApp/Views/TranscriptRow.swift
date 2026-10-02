import SwiftUI
import AudioDomain
import CaptionDomain
import SessionDomain

/// One segment in the reading column (§7, §9.1). Timestamp and source tag in the gutter,
/// translation first, source second, the 2pt "此刻" bar while the segment is still open and a
/// point of the time thread once it is final. `Equatable` on its inputs so an unchanged row is
/// skipped when the list re-evaluates.
struct SegmentRow: View, Equatable {
    /// What the session is doing with the page, which decides how a sentence that is not final
    /// reads: its reserved line must say only what is true (§8).
    enum Writing: Equatable {
        /// Heard and recognised: an open sentence is written live under the now bar.
        case live
        /// Paused: nothing is heard, so an open sentence waits under the now bar and says so.
        case paused
        /// Over (a finished session, a record read back): a sentence left open will never
        /// close, so it is set like a settled one — timestamp, thread point, full ink — with
        /// whatever note the record carries, and no now bar.
        case ended
    }

    let segment: CaptionSegment
    /// nil when the previous row came from the same lane (label shown on change only).
    let sourceTag: String?
    let serif: Bool
    let writing: Writing
    /// The time thread runs on from this sentence's point to the next one's (false before a
    /// gap, and after the last sentence of a finished page).
    let threadBelow: Bool
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: SegmentRow, b: SegmentRow) -> Bool {
        a.segment == b.segment && a.sourceTag == b.sourceTag && a.serif == b.serif
            && a.writing == b.writing && a.threadBelow == b.threadBelow
    }

    /// Still being written: not final, and the session is still writing the page.
    private var isOpen: Bool {
        segment.presentationState != .final && segment.presentationState != .frozen && writing != .ended
    }
    /// A partial is written a step quieter than settled text but still at 4.5 : 1 (at the old
    /// 60 % the live line was the hardest line on the page to read): 68 % of `ink2` on the black
    /// ground (5.3 : 1); paper needs 90 % for the same (4.6 : 1).
    private var sourceOpacity: Double {
        segment.presentationState == .preview && isOpen ? (theme.isDark ? 0.68 : 0.9) : 1
    }
    private var hasTranslation: Bool { segment.translation != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            gutter
                .frame(width: LLMetrics.gutterWidth - LLMetrics.space(4), alignment: .trailing)
                .padding(.trailing, LLMetrics.space(4))
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                if segment.mergedIntoTranslation == nil {
                    translationBlock
                }
                if !segment.sourceText.isEmpty {
                    // §6 "预览文本变化：直接替换"。The text itself carries no animation, whatever
                    // the transaction around it says (a neighbouring row arriving used to leak
                    // its fade into a partial replacement here and double the words for a frame);
                    // only the partial → settled fade animates, and only when that value flips.
                    Text(segment.sourceText)
                        .font(LLFont.transcriptSource)
                        .lineSpacing(LLLeading.transcriptSource)
                        .foregroundStyle(theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transaction { $0.animation = nil }
                        .opacity(sourceOpacity)
                        .animation(LLMotion.settle(reduceMotion), value: sourceOpacity)
                }
                if let reason = segment.incompleteReason {
                    Text("未完成 · \(reason)")
                        .font(LLFont.label)
                        .foregroundStyle(theme.ink3)
                } else if segment.corrected {
                    Text(segment.translation?.isStale == true ? "已修订 · 译文基于修订前原文" : "已修订")
                        .font(LLFont.label)
                        .foregroundStyle(theme.ink3)
                }
            }
            .padding(.leading, ReadingColumn.nowSlot + LLMetrics.space(3))
            .frame(maxWidth: LLMetrics.measure, alignment: .leading)
            .overlay(alignment: .leading) {
                NowMark(visible: isOpen)
            }
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                ThreadPoint()
                    .opacity(isOpen ? 0 : 1)
                    .animation(LLMotion.finalize(reduceMotion), value: isOpen)
            }
            .textSelection(.enabled)
            .contextMenu {
                Button("在翻译工作台中打开") {
                    TranslationFeature.shared.perform("query", text: segment.sourceText, dark: theme.isDark)
                }
                .disabled(segment.sourceText.isEmpty)
            }
            Spacer(minLength: 0)
        }
        // The thread from this row's point down to the next row's: the row's height plus the
        // air after it, measured from the point, lands on the next point (every row's first line
        // sits the same way). Resolved at layout, so it costs nothing while the page scrolls.
        .overlayPreferenceValue(ThreadPoint.Position.self, alignment: .topLeading) { point in
            if let point {
                GeometryReader { g in
                    ThreadPoint.Line(from: g[point], length: g.size.height + ReadingColumn.rowSpacing)
                }
                .opacity(threadBelow ? 1 : 0)
                .animation(LLMotion.finalize(reduceMotion), value: threadBelow)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The timestamp appears with the same 400ms as the "此刻" mark beside it fades and the
    /// thread's point takes its place: one event, one tempo (§7 定稿). Keyed on `isOpen`, so text
    /// edits never touch it.
    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(StatusCopy.timestamp(segment.startNs))
                .font(LLFont.timestamp)
                .foregroundStyle(theme.ink3)
                .opacity(isOpen ? 0 : 1)
                .animation(LLMotion.finalize(reduceMotion), value: isOpen)
            if let sourceTag {
                Text(sourceTag)
                    .font(LLFont.label)
                    .foregroundStyle(theme.ink3)
            }
        }
    }

    /// The translation's line is reserved from the sentence's first frame: an invisible line in
    /// the translation's own type holds the place, `slotLabel` sits in it while the sentence is
    /// open, and the translation fades into the same slot (240ms) when it lands. The source text
    /// underneath therefore never moves (§1 静止). The fade is keyed on the translation
    /// arriving, a boolean, so a revised or partial translation replaces its text with no
    /// animation. A sentence that ended without any translation (a translator failure, or one
    /// left open when the session ended) keeps no blank line.
    @ViewBuilder
    private var translationBlock: some View {
        if hasTranslation || isOpen {
            translationSlot
        }
    }

    /// What the open sentence is waiting for, and only while it is true: "翻译中" once it awaits
    /// its translation (the pipeline closes a pending guess on pause, so that one can still be
    /// under way while paused), otherwise "识别中" while the session listens and "已暂停" while
    /// it does not.
    private var slotLabel: String {
        if segment.presentationState == .awaitingTranslation { return "翻译中" }
        return writing == .paused ? "已暂停" : "识别中"
    }

    private var translationSlot: some View {
        ZStack(alignment: .leading) {
            Text(" ")
                .font(LLFont.transcriptTarget(serif: serif))
                .hidden()
            if let t = segment.translation {
                Text(t.text)
                    .font(LLFont.transcriptTarget(serif: serif))
                    .lineSpacing(serif ? LLLeading.transcriptTargetSerif : LLLeading.transcriptTarget)
                    .foregroundStyle(theme.readingInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .transaction { $0.animation = nil }
                    .opacity(t.isStale ? 0.6 : 1)
                    .animation(LLMotion.settle(reduceMotion), value: t.isStale)
                    .transition(LLMotion.appear)
            } else if isOpen {
                // The reserved line says what the sentence is waiting for, so the now bar beside
                // it spans two written lines instead of pointing at an empty one.
                Text(slotLabel)
                    .font(LLFont.label)
                    .foregroundStyle(theme.ink3)
                    .transition(LLMotion.appear)
            }
        }
        .animation(LLMotion.settle(reduceMotion), value: hasTranslation)
    }

    private var accessibilityText: String {
        var s = (isOpen ? "" : StatusCopy.timestamp(segment.startNs) + "，") + (sourceTag ?? "") + "。"
        if let t = segment.translation { s += t.text + "。" }
        // A partial is left out while it still changes; once it is set, it is read.
        if !isOpen { s += segment.sourceText }
        if segment.isIncomplete { s += "。未完成" }
        return s
    }
}

/// A gap is the one place a rule appears between paragraphs (§4): the fact in small text on the
/// text column, then a hairline running out to the measure and fading there. It stands 24 pt
/// clear of its neighbours (the column's 32 less 8), so it reads as a break in the text, not a
/// hole in it.
struct GapRow: View, Equatable {
    let gap: CaptionGap
    @Environment(\.theme) private var theme

    nonisolated static func == (a: GapRow, b: GapRow) -> Bool { a.gap == b.gap }

    var body: some View {
        HStack(spacing: LLMetrics.space(3)) {
            Text(StatusCopy.gap(gap))
                .font(LLFont.label)
                .foregroundStyle(theme.ink3)
                .fixedSize()
            FadingRule()
        }
        .padding(.leading, ReadingColumn.textInset)
        .frame(maxWidth: ReadingColumn.block, alignment: .leading)
        .padding(.vertical, -LLMetrics.space(2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatusCopy.gap(gap))
    }
}

/// One point of the time thread (round 12): each final sentence leaves a small, dim point in the
/// now bar's slot beside its first line, and a hairline joins it to the next sentence's point,
/// so the slot reads as one thread of past moments running down into its bright head, the bar
/// on the open sentence (or the "正在听" dot). A gap breaks the thread; a finished page ends it
/// at its last sentence. The point sits a little above the baseline, on the middle of the
/// timestamp's digits. Drawn once (no clock, no twinkle — §1 静止) and invisible to VoiceOver:
/// the timestamp already says it.
struct ThreadPoint: View {
    @Environment(\.theme) private var theme

    static let diameter: CGFloat = 1.6
    /// Height of the point's centre above the first baseline.
    nonisolated static let lift: CGFloat = 4.5

    var body: some View {
        Circle()
            .fill(theme.ink3.opacity(theme.isDark ? 0.45 : 0.4))
            .frame(width: Self.diameter, height: Self.diameter)
            .frame(width: ReadingColumn.nowSlot)
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Self.lift }
            .anchorPreference(key: Position.self, value: .center) { $0 }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Where the row's point is, so the row can draw the thread from it.
    struct Position: PreferenceKey {
        static var defaultValue: Anchor<CGPoint>? { nil }
        static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
            value = value ?? nextValue()
        }
    }

    /// The thread between two points: a 0.5 pt hairline, far quieter than the points it joins,
    /// so the points still lead and the line only says they belong together.
    struct Line: View {
        let from: CGPoint
        let length: CGFloat
        @Environment(\.theme) private var theme

        var body: some View {
            Rectangle()
                .fill(theme.ink3.opacity(theme.isDark ? 0.2 : 0.22))
                .frame(width: 0.5, height: length)
                .position(x: from.x, y: from.y + length / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Tail placeholder while a lane is running but has no open segment.
struct ListeningRow: View, Equatable {
    let sourceTag: String?
    let text: String
    let dotMode: LiveDot.Mode
    @Environment(\.theme) private var theme

    nonisolated static func == (a: ListeningRow, b: ListeningRow) -> Bool {
        a.sourceTag == b.sourceTag && a.text == b.text && a.dotMode == b.dotMode
    }

    /// The dot sits in the now bar's slot, at the head of the time thread, where the next
    /// sentence's bar will appear; the words start on the text column.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(sourceTag ?? "")
                .font(LLFont.label)
                .foregroundStyle(theme.ink3)
                .frame(width: LLMetrics.gutterWidth - LLMetrics.space(4), alignment: .trailing)
                .padding(.trailing, LLMetrics.space(4))
            LiveDot(mode: dotMode, color: theme.accent)
                .frame(width: ReadingColumn.nowSlot)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 1 }
                .padding(.trailing, LLMetrics.space(3))
            Text(text)
                .font(LLFont.body)
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }
}
