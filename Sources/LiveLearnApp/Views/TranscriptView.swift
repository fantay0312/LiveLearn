import SwiftUI
import AudioDomain
import CaptionDomain
import SessionDomain

/// The reading column: a paragraph flow under a masthead, ending on the horizon (§9.1).
///
/// The body reads only precomputed model state (`transcriptRows`, `listeningRows`, `lanes`,
/// `recoveryAdvice`, the session state that decides how an open sentence reads), so it
/// re-evaluates when a caption or a lane or session state changes, not on every level tick or
/// clock second. Rows are `Equatable`, so an unchanged row skips its body.
///
/// Horizontally everything hangs from `ReadingColumn`: the gutter + measure block is centred in
/// `width` (the page's width, from the window layout, so offscreen renders place it too).
struct TranscriptView: View {
    var width: CGFloat
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    /// True while the reader is at the tail: new sentences keep the view pinned there. Only a
    /// scroll gesture by the reader (scroll phase `interacting`) turns it off; a gesture that
    /// ends back at the tail, or "回到实时", turns it on again. Content growth never changes it,
    /// so a long sentence arriving can never silently un-pin the view.
    @State private var followsTail = true

    /// Sizes only: when either changes while following, re-pin to the tail.
    private struct ScrollProbe: Equatable {
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }

    private static func distanceToTail(_ g: ScrollGeometry) -> CGFloat {
        g.contentSize.height - (g.contentOffset.y + g.containerSize.height)
    }

    /// Space above the first item of the column (the masthead, or the empty page's opening
    /// line, which sits exactly where a masthead would). As deep as `topFade`, so at rest the
    /// fade holds only ground; with the header's 48 pt above it, the masthead's opening line
    /// shares its baseline with the rail's "记录" (`SidebarView.headerTop`).
    static let topInset = LLMetrics.space(6)
    /// The scroll area's edges are drawn as fades, not cuts: a sentence leaving at the top thins
    /// out over 32 pt, and at the bottom the column sinks into the horizon over 24 pt. The
    /// masthead does not rely on the top fade: its two lines are taller than the fade, which
    /// would leave the facts legible under a sliced title, so it leaves as one unit (`rows`).
    static let topFade = LLMetrics.space(6)
    static let bottomFade = LLMetrics.space(5)
    /// The visible scroll area, the same space on the live and the static path: the masthead
    /// reads its own position in it.
    private static let viewport = "reading-viewport"

    private var leading: CGFloat { ReadingColumn.leading(in: width) }
    private var blockWidth: CGFloat { ReadingColumn.width(in: width) }
    private var trailing: CGFloat { max(0, width - leading - blockWidth) }
    private var isEmpty: Bool { model.transcriptRows.isEmpty && model.listeningRows.isEmpty }
    /// Nothing to read and nothing coming: the column is the empty page (`emptyPage`), which
    /// carries a recovery note itself instead of hanging it above the column.
    private var showsEmptyPage: Bool { !model.isActive && isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // A rare state, so it may arrive (180ms fade, keyed on presence); it leaves at once.
            // The rows below take their new place without animation: old text never slides.
            // Pinned above the column, so a page following its tail never scrolls the note away.
            Group {
                if let advice = model.recoveryAdvice, !showsEmptyPage {
                    RecoveryBanner(advice: advice)
                        .frame(width: max(0, blockWidth - ReadingColumn.textInset), alignment: .leading)
                        .padding(.leading, leading + ReadingColumn.textInset)
                        .padding(.top, LLMetrics.space(4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(LLMotion.appear)
                }
            }
            .animation(LLMotion.arrive(reduceMotion), value: model.recoveryAdvice != nil)
            Group {
                if staticRender {
                    // The scroll view at rest, drawn without one: a record from its start, anything
                    // else pinned to its tail, as the live page is.
                    RestingScroll(pinsTail: !model.isViewingRecord) {
                        rows
                    }
                    .coordinateSpace(.named(Self.viewport))
                    .clipped()
                    .mask { ReadingEdges() }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            rows
                        }
                        .coordinateSpace(.named(Self.viewport))
                        // The system preference decides; overlay bars only show while scrolling.
                        .scrollIndicators(.automatic)
                        .onScrollGeometryChange(for: ScrollProbe.self) { g in
                            ScrollProbe(contentHeight: g.contentSize.height, containerHeight: g.containerSize.height)
                        } action: { _, _ in
                            // The transcript grew, reflowed or the window resized: stay on the tail.
                            if followsTail && !model.isViewingRecord { proxy.scrollTo("tail", anchor: .bottom) }
                        }
                        .onScrollPhaseChange { _, phase, context in
                            switch phase {
                            case .tracking, .interacting:
                                // The 回到实时 button fades in (180ms) as the reader leaves the tail.
                                withAnimation(LLMotion.arrive(reduceMotion)) { followsTail = false }
                            case .idle, .decelerating:
                                // A gesture that comes to rest at the tail resumes following; the button
                                // leaves a little faster than it came.
                                if !followsTail, Self.distanceToTail(context.geometry) <= 48 {
                                    withAnimation(LLMotion.exit(reduceMotion)) { followsTail = true }
                                }
                            default:
                                break
                            }
                        }
                        .onChange(of: model.sessionID) { _, _ in
                            followsTail = !model.isViewingRecord
                            proxy.scrollTo(model.isViewingRecord ? "start" : "tail", anchor: model.isViewingRecord ? .top : .bottom)
                        }
                        .mask { ReadingEdges() }
                        .overlay(alignment: .bottomTrailing) {
                            if !followsTail && model.isActive {
                                Button("回到实时") {
                                    withAnimation(LLMotion.exit(reduceMotion)) { followsTail = true }
                                    withAnimation(LLMotion.arrive(reduceMotion)) { proxy.scrollTo("tail", anchor: .bottom) }
                                }
                                .buttonStyle(TextButtonStyle(flush: true))
                                // A patch of ground, feathered, under the word: it covers the text the
                                // word floats over without drawing a plate of its own.
                                .background {
                                    RoundedRectangle(cornerRadius: LLMetrics.Radius.card, style: .continuous)
                                        .fill(theme.ground)
                                        .padding(.horizontal, -LLMetrics.space(3))
                                        .padding(.vertical, -LLMetrics.space(1))
                                        .blur(radius: 6)
                                }
                                .padding(.trailing, trailing)
                                .padding(.bottom, LLMetrics.space(1))
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
            // On the column, not the page, and outside the scroll content: its opening line sits
            // where a masthead would, and a recovery note on it can never scroll away.
            .overlay(alignment: .topLeading) {
                if showsEmptyPage {
                    emptyPage
                }
            }
            // The column ends in a little ground above the horizon, so its last line has
            // somewhere to fade into.
            Spacer().frame(height: LLMetrics.space(3))
        }
    }

    /// Nothing to read: one opening line where a record's masthead would be, one sentence, and
    /// the way forward — on the text column, no symbol and no button plate (§2), and said once
    /// (the rail stays empty). Before any session the sentence is the invitation; after a
    /// session that caught nothing it says what to check. A session that failed with a known
    /// fix opens on the recovery note instead (`recoveryMasthead`). The note may arrive (180ms
    /// fade, keyed on presence), like the one above the column.
    private var emptyPage: some View {
        let ended = model.sessionState != .idle
        return VStack(alignment: .leading, spacing: 0) {
            if let advice = model.recoveryAdvice {
                recoveryMasthead(advice)
                    .transition(LLMotion.appear)
            } else {
                Text(ended ? "这次会话没有识别到内容" : "还没有翻译记录")
                    .font(LLFont.display)
                    .foregroundStyle(theme.ink)
                Text(ended ? "可以在首页检查音源和语言，然后重新开始。"
                           : "从首页选择音源并开始翻译，识别到的内容会显示在这里。")
                    .font(LLFont.body)
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, LLMetrics.space(3))
                Button("前往首页") { model.requestHome() }
                    .buttonStyle(TextButtonStyle(flush: true, strong: true))
                    .padding(.top, LLMetrics.space(4))
            }
        }
        .animation(LLMotion.arrive(reduceMotion), value: model.recoveryAdvice != nil)
        .frame(maxWidth: max(0, blockWidth - ReadingColumn.textInset), alignment: .leading)
        .padding(.leading, leading + ReadingColumn.textInset)
        .padding(.top, Self.topInset)
    }

    /// A failed session that caught nothing, read as a masthead (`RecordMasthead`'s grammar):
    /// what it needs is the opening line, in the display size on the rail's baseline, and the
    /// facts under it say, in the error colour, that it stopped with nothing to read. Then the
    /// cause, and the fix as the page's one strong word — 15/500 ink, as on Home — so it reads
    /// as the way out, not as one more line of the explanation above it.
    private func recoveryMasthead(_ advice: RecoveryAdvice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                Text(advice.title)
                    .font(LLFont.display)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("已停止 · 没有识别到内容")
                    .font(LLFont.labelStrong)
                    .foregroundStyle(theme.brick)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(advice.detail)
                .font(LLFont.body)
                .lineSpacing(LLLeading.body)
                .foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, LLMetrics.space(5))
            if let action = advice.action {
                Button { model.perform(action) } label: {
                    Text(action.label).font(LLFont.heading)
                }
                .buttonStyle(TextButtonStyle(tint: theme.ink, flush: true))
                .padding(.top, LLMetrics.space(2))
            }
        }
    }

    /// The masthead, then the sentences 32 pt apart, then the tail. The masthead and the tail
    /// stand outside the lazy stack so the column's top inset, the air under the masthead and
    /// the air under the last row are set on their own, not by the stack's spacing.
    private var rows: some View {
        let rest = Self.topInset, viewport = Self.viewport
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Self.topInset).id("start")
            if model.isActive || !isEmpty {
                RecordMasthead()
                    // Leaves as one unit, so title and facts never part and no glyph is ever cut:
                    // whole at its resting inset, dissolving on the top fade's own curve (t²)
                    // over the first 16 pt it moves, gone while its top is still 16 pt inside the
                    // page. Spread over the whole 32 pt, a page resting a little past full would
                    // keep a dim ghost of the title. Geometry only: no clock, no body pass while
                    // scrolling; at rest (every record opened from its start) it is untouched.
                    .visualEffect { content, geometry in
                        let top = geometry.frame(in: .named(viewport)).minY
                        let t = min(1, max(0, (top - rest / 2) / (rest / 2)))
                        return content.opacity(t * t)
                    }
                    .padding(.bottom, LLMetrics.space(6))
                    .transition(LLMotion.arriveTransition)
            }
            if staticRender {
                VStack(alignment: .leading, spacing: ReadingColumn.rowSpacing) { rowContent }
            } else {
                // Keyed on both counts: a "正在听" placeholder taking the tail after a sentence
                // finalises changes only the second one. Text edits change neither, so nothing
                // fires on a partial replacement.
                LazyVStack(alignment: .leading, spacing: ReadingColumn.rowSpacing) { rowContent }
                    .animation(LLMotion.arrive(reduceMotion), value: [model.transcriptRows.count, model.listeningRows.count])
            }
            // The last row rests one bottom fade (24) plus the column's 12 pt foot — 36 pt —
            // above the horizon rule, just clear of the fade.
            Color.clear.frame(height: Self.bottomFade).id("tail")
        }
        .padding(.leading, leading).padding(.trailing, trailing)
        .animation(LLMotion.arrive(reduceMotion), value: model.isActive || !isEmpty)
    }

    @ViewBuilder
    private var rowContent: some View {
        let writing: SegmentRow.Writing = !model.isActive ? .ended : model.sessionState == .paused ? .paused : .live
        let threaded = Self.threadedRows(model.transcriptRows, headFollows: !model.listeningRows.isEmpty)
        ForEach(model.transcriptRows) { row in
            switch row.item {
            case .segment(let seg):
                SegmentRow(segment: seg, sourceTag: row.tag, serif: model.settings.readingSerif,
                           writing: writing, threadBelow: threaded.contains(row.id))
                    .equatable()
                    .id(seg.id)
                    .transition(LLMotion.arriveTransition)
            case .gap(let gap):
                GapRow(gap: gap)
                    .equatable()
                    .id(gap.id)
                    .transition(LLMotion.arriveTransition)
            }
        }
        ForEach(model.listeningRows) { row in
            // The placeholder leaves the instant a sentence takes its place; a default
            // (opacity) removal overlapped the two for 180 ms on every new sentence.
            ListeningRow(sourceTag: row.tag, text: row.text, dotMode: row.live ? .live : .waiting)
                .equatable()
                .id(row.id)
                .transition(LLMotion.arriveTransition)
        }
    }

    /// The sentences whose time thread runs on to the next point: each one followed by another
    /// sentence, and the last one when the "正在听" placeholder (the thread's head) follows it.
    /// A gap breaks the thread; the last sentence of a finished page ends it. One pass, per
    /// change of the rows, never per frame.
    private static func threadedRows(_ rows: [TranscriptRow], headFollows: Bool) -> Set<String> {
        var ids = Set<String>()
        for (i, row) in rows.enumerated() {
            guard case .segment = row.item else { continue }
            if i + 1 < rows.count {
                if case .segment = rows[i + 1].item { ids.insert(row.id) }
            } else if headFollows {
                ids.insert(row.id)
            }
        }
        return ids
    }
}

/// Offscreen, `ImageRenderer` draws no scroll view, so the column is laid out as a scroll view
/// shows it at rest: from the top when it fits or when it is a record (records open from the
/// beginning), otherwise with its tail on the bottom edge and the start cut above, as a live
/// transcript that follows its tail shows it.
private struct RestingScroll: Layout {
    var pinsTail: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let height = content.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let y = pinsTail && height > bounds.height ? bounds.maxY - height : bounds.minY
        content.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
    }
}

/// The mask that turns the scroll area's two cuts into fades (the settings page's
/// `SettingsScrollEdge`, longer at both ends for the page's larger type).
///
/// Alpha rises as the square of the distance into the fade. On the black ground lightness
/// follows alpha far from linearly: a linear ramp kept a 24 pt line legible for most of the fade
/// and read as a slice through the glyphs; the square reads as an even dissolve.
private struct ReadingEdges: View {
    private static var dissolve: Gradient {
        Gradient(stops: stride(from: 0.0, through: 1.0, by: 0.25).map { t in
            Gradient.Stop(color: .black.opacity(t * t), location: t)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(gradient: Self.dissolve, startPoint: .top, endPoint: .bottom)
                .frame(height: TranscriptView.topFade)
            Color.black
            LinearGradient(gradient: Self.dissolve, startPoint: .bottom, endPoint: .top)
                .frame(height: TranscriptView.bottomFade)
        }
        .accessibilityHidden(true)
    }
}
