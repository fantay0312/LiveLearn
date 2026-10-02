import SwiftUI
import CaptionDomain

/// The vocabulary window reviews the session currently displayed in the main window.
///
/// Round 12: the review reads like the records transcript it comes from — the time in a gutter,
/// the sentence on the text column with each misheard span dotted in ochre, the candidate under
/// it, and the two decisions as words on the reason's line. Fading rules between sentences.
struct VocabularyCorrectionsView: View {
    let model: AppModel
    let query: String
    var onClearSearch: () -> Void = {}
    @Environment(\.theme) private var theme
    @State private var busy = false
    @State private var feedback = ""
    @State private var feedbackIsError = false

    private var segments: [CaptionSegment] {
        model.captions.segments.filter { segment in
            (!(segment.vocabularyCandidates ?? []).isEmpty || segment.corrected)
                && (query.isEmpty || segment.sourceText.localizedStandardContains(query)
                    || (segment.vocabularyCandidates ?? []).contains { $0.replacement.localizedStandardContains(query) })
        }
    }

    var body: some View {
        ScrollContainer {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("确认仅修改本处；保留原文不影响后续识别。")
                        .font(LLFont.body).foregroundStyle(theme.ink2).fixedSize(horizontal: false, vertical: true)
                    if !feedback.isEmpty {
                        Text(feedback)
                            .font(LLFont.label).foregroundStyle(feedbackIsError ? theme.brick : theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if segments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(query.isEmpty ? "暂无待确认项" : "没有匹配的修正项").font(LLFont.body).foregroundStyle(theme.ink2)
                        if !query.isEmpty { Button("清除搜索", action: onClearSearch).buttonStyle(TextButtonStyle(flush: true, strong: true)) }
                    }.padding(.vertical, 24)
                }
                ForEach(segments) { segment in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(StatusCopy.timestamp(segment.startNs)).font(LLFont.timestamp).foregroundStyle(theme.ink3)
                                .frame(width: LLMetrics.gutterWidth, alignment: .leading)
                            segmentReview(segment)
                        }
                        .padding(.bottom, 20)
                        FadingRule()
                    }
                }
            }
            // The intro line on the first rail name's baseline; the review on the page's measure,
            // so the two decisions stay beside the sentence they settle.
            .padding(.top, 20)
            .frame(maxWidth: VocabularyPageMetrics.measure, alignment: .leading)
            .padding(.leading, VocabularyPageMetrics.contentLeading).padding(.trailing, VocabularyPageMetrics.contentTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
        }
        .onChange(of: model.sessionID) { _, _ in feedback = "" }
    }

    /// One sentence under review: the sentence with its misheard spans marked, each candidate
    /// with its two decisions, and what a confirmed correction left behind.
    private func segmentReview(_ segment: CaptionSegment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.marked(segment.sourceText, spans: segment.vocabularyCandidates ?? [], ink: theme.ink, mark: theme.ochre))
                .font(LLFont.bodyStrong)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ForEach(segment.vocabularyCandidates ?? []) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(candidate.original).foregroundStyle(theme.ink2)
                        Text("→").foregroundStyle(theme.ink3)
                        Text(candidate.replacement).foregroundStyle(theme.ink)
                    }.font(LLFont.bodyStrong).textSelection(.enabled)
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(candidate.reason.label + " · 待确认").font(LLFont.label).foregroundStyle(theme.ink3)
                        Spacer(minLength: 8)
                        Button("保留原文") { review(segment, candidate, confirm: false) }
                            .buttonStyle(TextButtonStyle(tint: theme.ink3, flush: true))
                        Button("确认本处") { review(segment, candidate, confirm: true) }
                            .buttonStyle(TextButtonStyle(flush: true))
                            .accessibilityLabel("将本处\(candidate.original)修正为\(candidate.replacement)")
                    }.disabled(busy)
                }
            }
            if segment.corrected, let previous = segment.originalRecognitionText ?? segment.history.first {
                Text("识别原文：\(previous)").font(LLFont.label).foregroundStyle(theme.ink2).textSelection(.enabled)
            }
            if segment.corrected, hasStaleTranslation(segment) {
                Text("原文已修订；现有译文仍基于修订前的内容。")
                    .font(LLFont.label).foregroundStyle(theme.ink2)
            }
        }
    }

    /// The sentence with each candidate's span underlined by a dotted ochre rule — where the
    /// sentence was misheard, shown in place. A span that no longer matches the text (the
    /// sentence was revised) is left unmarked rather than guessed.
    static func marked(_ text: String, spans: [VocabularyCorrectionCandidate], ink: Color, mark: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = ink
        let characters = Array(text)
        for span in spans where span.start >= 0 && span.length > 0 && span.start + span.length <= characters.count {
            guard String(characters[span.start..<span.start + span.length]) == span.original else { continue }
            let lower = attributed.index(attributed.startIndex, offsetByCharacters: span.start)
            let upper = attributed.index(lower, offsetByCharacters: span.length)
            attributed[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot, color: mark)
        }
        return attributed
    }

    private func review(_ segment: CaptionSegment, _ candidate: VocabularyCorrectionCandidate, confirm: Bool) {
        let sessionID = model.sessionID
        busy = true
        Task { @MainActor in
            let error = await model.reviewVocabularyCandidate(sessionID: sessionID, segmentID: segment.id,
                revision: segment.sourceRevision, candidate: candidate, confirm: confirm)
            if sessionID == model.sessionID {
                feedback = error ?? (confirm ? "已修正这一处，修订前的原文已保留。" : "已保留原文。")
                feedbackIsError = error != nil
            }
            busy = false
        }
    }

    private func hasStaleTranslation(_ segment: CaptionSegment) -> Bool {
        segment.translation?.isStale == true || model.captions.segments.contains {
            $0.translation?.isStale == true && $0.translation?.coveredSegmentIDs.contains(segment.id) == true
        }
    }
}
