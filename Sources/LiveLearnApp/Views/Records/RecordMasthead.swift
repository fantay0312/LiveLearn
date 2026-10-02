import SwiftUI
import SessionStorage

/// The top of a record (round 12): what the page is, before the first sentence. One opening
/// line in the display size — the record's date and time, or "当前会话" while the session runs
/// (the live row's own name in the rail, true whether it listens or is paused) — and one line of
/// facts under it in the label size, on the text column. It is the first item of the column, so
/// it scrolls away with the text rather than holding a band of the window, and a live transcript
/// (which follows its tail) shows it only until the page fills.
///
/// The facts say what the horizon under the page does not: a record's summary, or for the live
/// session its day, when it began and its sentences so far (the horizon already carries its
/// route, clock and state).
///
/// Its own view: it reads the record and, while live, the transcript rows, so a new sentence
/// repaints these two lines, not the column.
struct RecordMasthead: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let record = model.currentRecord
        VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
            CrossfadeText(text: record.map(RecordFacts.masthead) ?? "当前会话",
                          font: LLFont.display, color: theme.ink, alignment: .leading)
            CrossfadeText(text: record.map(Self.facts) ?? liveFacts,
                          font: LLFont.label.monospacedDigit(), color: theme.ink3, alignment: .leading)
        }
        .padding(.leading, ReadingColumn.textInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// "6 句 · 6:12 · Safari · 英语 → 中文 · 缺口 1 处": the record's summary, and its gaps when
    /// it has any (the transport says the same while the record is open, the masthead says it
    /// where the reading starts).
    static func facts(_ r: SessionRecord) -> String {
        let gaps = r.archive.gapCount
        return RecordFacts.detail(r) + (gaps > 0 ? " · 缺口 \(gaps) 处" : "")
    }

    /// "9月27日 周日 19:25 开始 · 6 句": the live session's own day and start, and its sentences so
    /// far, counted the way its record will count them (a sentence cut off unfinished is not
    /// one). A model that never started a session (the offscreen fixtures) has no start and
    /// writes today's date alone.
    private var liveFacts: String {
        let sentences = model.transcriptRows.reduce(0) { count, row in
            if case .segment(let s) = row.item, !s.isIncomplete { return count + 1 }
            return count
        }
        let opened = model.sessionStartedAt.map { "\(RecordFacts.day($0)) \(RecordFacts.time($0)) 开始" }
            ?? RecordFacts.day(Date())
        return sentences > 0 ? "\(opened) · \(sentences) 句" : opened
    }
}
