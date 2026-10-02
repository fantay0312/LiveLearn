import SwiftUI
import AudioDomain
import SessionDomain
import MacAudio
import SessionStorage

/// Collapsible history at the left; navigation and session setup live in the main area.
///
/// The records rail (round 12) speaks the Observatory Rail's grammar: bare text on the ground,
/// no icons, no fills, no boxed search. It has two verticals and nothing else — an 8 pt slot
/// centred at `slotCenter` that holds the selection star or the live session's now bar, and the
/// text column at `textColumn` on which the header, the magnifier, the day labels and every row
/// start.
struct SidebarView: View {
    var width: CGFloat = 280
    @Binding var query: String
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var pendingDeletion: SessionRecord?

    /// Centre of the mark slot (selection star, live bar).
    static let slotCenter: CGFloat = 12
    /// Where every word in the rail starts.
    static let textColumn: CGFloat = 24
    /// Where the rail's words end: the "+" glyph, the search rule, the row flags.
    static let trailingInset: CGFloat = 20
    /// Space above the header row. The 15 pt "记录" centred in its 28 pt row then sits on the
    /// same baseline as the reading column's 24 pt masthead (`TranscriptView.topInset` below the
    /// same edge), so the rail and the page open on one line, as Settings' rail and page do.
    static let headerTop: CGFloat = 36
    /// The header row's height: `GlyphButtonStyle`'s 28 pt square around "+". The vocabulary
    /// page centres its top line on this row (`VocabularyPageMetrics.embeddedTop`).
    static let headerRowHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("记录").font(LLFont.heading).foregroundStyle(theme.ink)
                Spacer()
                Button { model.clearCompleted() } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                }
                .buttonStyle(GlyphButtonStyle(flush: .trailing))
                .disabled(model.isActive).accessibilityLabel("新会话")
                .help(model.isActive ? "结束当前会话后再开始新会话" : "新会话")
            }
            .frame(height: Self.headerRowHeight)
            .padding(.leading, Self.textColumn).padding(.trailing, Self.trailingInset)
            .padding(.top, Self.headerTop).padding(.bottom, LLMetrics.space(3))
            // Nothing to search before the first record: the field would be a promise with
            // nothing behind it. It leaves with its focus, and with its query (below), so a
            // search nobody can see never filters the next record.
            if !model.records.isEmpty {
                BareSearchField(placeholder: "搜索记录", text: $query, accessibilityName: "搜索翻译记录",
                                clearName: "清除记录搜索", focus: $searchFocused)
                    .padding(.leading, Self.textColumn).padding(.trailing, Self.trailingInset)
                    .padding(.bottom, LLMetrics.space(2))
            }
            ScrollContainer {
                recordsGroup.padding(.bottom, 20)
            }
        }
        .frame(width: width)
        .onChange(of: model.records.isEmpty) { _, empty in
            if empty { query = "" }
        }
        .alert("删除这条记录？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { record in
            Button("取消", role: .cancel) { pendingDeletion = nil }
            Button("删除", role: .destructive) { model.delete(record); pendingDeletion = nil }
        } message: { record in
            Text("\(RecordFacts.dayTitle(record.startedAt)) \(RecordFacts.time(record.startedAt)) · \(record.segmentCount) 句。" + (record.saved ? "将同时删除本机文件，此操作无法撤销。" : "将移除尚未保存的内容，此操作无法撤销。"))
        }
    }

    // MARK: 记录

    /// One line of the ledger: the session in progress, or a finished one. The live session and
    /// the record it becomes share an id (the session id), so the row keeps its identity and
    /// its place when the session ends: the now bar fades, the title becomes the record's first
    /// sentence and the clock becomes the summary, and nothing below it moves.
    private enum LedgerRow: Identifiable {
        case live(String)
        case record(SessionRecord)

        var id: String {
            switch self {
            case .live(let id): return id
            case .record(let r): return r.id
            }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let rows: [LedgerRow]
        var id: Date { day }

        /// Finished records in the group that only live in memory until they are saved.
        var unsaved: Int {
            rows.reduce(0) { count, row in
                if case .record(let r) = row, !r.saved { return count + 1 }
                return count
            }
        }
    }

    /// What the ledger shows, and what changing it should animate.
    private struct LedgerKey: Equatable {
        var ids: [String]
        var active: Bool
        var message: String?
    }

    private var dayGroups: [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [LedgerRow]] = [:]
        if model.isActive {
            // The running session heads today's group, where its record will land.
            let today = calendar.startOfDay(for: Date())
            order.append(today)
            byDay[today] = [.live(model.sessionID)]
        }
        for r in model.records where !(model.isActive && r.id == model.sessionID) {
            guard Self.matches(r, query: query) else { continue }
            let day = calendar.startOfDay(for: r.startedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(.record(r))
        }
        return order.map { DayGroup(day: $0, title: RecordFacts.dayTitle($0), rows: byDay[$0] ?? []) }
    }

    private var recordsGroup: some View {
        // Grouped once per body: the search filter reads every segment of every record.
        let dayGroups = self.dayGroups
        let key = LedgerKey(ids: dayGroups.flatMap { $0.rows.map(\.id) }, active: model.isActive, message: model.storeMessage)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(dayGroups) { group in
                dayLabel(group)
                    .transition(LLMotion.arriveTransition)
                ForEach(group.rows) { row in
                    ledgerRow(row)
                        .transition(LLMotion.arriveTransition)
                }
            }
            // With no records at all the rail stays empty under its header: the reading pane
            // says so once, in words, with the way forward. An unmatched search is the rail's
            // own business and offers its own way back.
            if dayGroups.isEmpty && !model.records.isEmpty && !query.isEmpty {
                VStack(alignment: .leading, spacing: LLMetrics.space(1)) {
                    Text("没有匹配的记录")
                        .font(LLFont.label)
                        .foregroundStyle(theme.ink3)
                    Button("清除搜索") { query = ""; searchFocused = true }
                        .buttonStyle(TextButtonStyle(flush: true))
                }
                .padding(.leading, Self.textColumn)
                .padding(.top, LLMetrics.space(2))
            }
            if let message = model.storeMessage {
                Text(message)
                    .font(LLFont.label)
                    .lineSpacing(2)
                    .foregroundStyle(theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textColumn).padding(.trailing, Self.trailingInset)
                    .padding(.top, LLMetrics.space(2))
                    .transition(LLMotion.appear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A new row lands the way a sentence lands on the page: it fades in and rises 4pt; the
        // rows already there stay where they are.
        .animation(LLMotion.arrive(reduceMotion), value: key)
    }

    /// 今天 / 昨天 / 9月5日 in the settings rail's group-label type, with the one fact about the
    /// group that needs attention at its trailing end: how many of its records are unsaved (and
    /// go when the app quits). Said once per day instead of "未保存" down every row, where a
    /// word repeated on every line stops being read.
    private func dayLabel(_ group: DayGroup) -> some View {
        let unsaved = group.unsaved
        return HStack(alignment: .firstTextBaseline, spacing: LLMetrics.space(2)) {
            Text(group.title)
                .font(LLFont.labelStrong)
                .foregroundStyle(theme.ink3)
            Spacer(minLength: 0)
            if unsaved > 0 {
                Text("\(unsaved) 条未保存")
                    .font(LLFont.label.monospacedDigit())
                    .foregroundStyle(theme.ink3)
                    .help("未保存的记录在退出软件后消失；右键记录可保存到本机")
            }
        }
        .padding(.leading, Self.textColumn).padding(.trailing, Self.trailingInset)
        .padding(.top, LLMetrics.space(4))
        .padding(.bottom, LLMetrics.space(1))
        .accessibilityElement(children: .combine)
    }

    /// The row for a live session and for a record are one view built by one expression (not
    /// two branches of a switch, which SwiftUI would treat as two identities and cross-fade as
    /// a removal and an insertion), so the one becomes the other in place.
    private func ledgerRow(_ row: LedgerRow) -> some View {
        let record: SessionRecord? = { if case .record(let r) = row { return r }; return nil }()
        let time = record.map { RecordFacts.time($0.startedAt) }
        let headline = record.flatMap(RecordFacts.headline)
        let flag = record.map { $0.interrupted ? "未正常结束" : ($0.saved ? "" : "未保存") }
            ?? (model.settings.autoSaveSessions ? "自动保存中" : "未保存")
        let accessibility: String = {
            if let record, let time {
                let title = headline.map { "，" + $0 } ?? ""
                return "\(RecordFacts.dayTitle(record.startedAt)) \(time)\(title)，\(RecordFacts.detail(record))\(flag.isEmpty ? "" : "，" + flag)"
            }
            return "当前会话，\(flag)"
        }()
        return SessionLedgerRow(live: record == nil,
                                title: headline ?? time ?? "当前会话",
                                // "未保存" is the group's note; a row speaks only when it went wrong.
                                trailing: record == nil || record?.interrupted == true ? flag : "",
                                meta: record.map(RecordFacts.meta),
                                selected: record.map { model.currentRecord?.id == $0.id } ?? false,
                                accessibility: accessibility,
                                action: { if let record { model.showRecord(record) } else { model.mainPage = .transcript } })
            .contextMenu { if let record { recordMenu(record) } }
    }

    static func matches(_ record: SessionRecord, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { part in
            record.title.localizedStandardContains(part)
                || record.archive.lanes.contains { $0.displayName.localizedStandardContains(part) }
                || record.archive.segments.contains { $0.sourceText.localizedStandardContains(part) || $0.translation?.text.localizedStandardContains(part) == true }
        }
    }

    @ViewBuilder
    private func recordMenu(_ r: SessionRecord) -> some View {
        if !r.saved {
            Button("保存到本机") { model.save(r) }
        }
        Menu("导出为…") {
            ForEach(ExportFormat.allCases) { format in
                Button(format.label) { ExportPanel.present(r, format: format, model: model) }
            }
        }
        if r.saved {
            Button("在 Finder 中显示") { model.revealInFinder(r) }
        }
        Divider()
        Button(r.saved ? "删除记录（含文件）…" : "移除记录…", role: .destructive) { pendingDeletion = r }
    }

    /// One ledger row in either of its two lives. Live: "当前会话" in ink, the now bar in the
    /// slot, the clock and the save policy underneath. Finished: the record's first sentence,
    /// then "17:05 · 6 句 · 6:12 · Safari", and a flag only when the record went wrong; clickable
    /// to read it back. Title and flag change through a 150ms fade, the bar fades over 400ms
    /// (the same beat as a sentence finalising), and the two lives are the same height, so the
    /// rows below never move.
    ///
    /// No fill in any state. The record being read carries a stamped star in the slot, its
    /// title in `ink` and its meta line a step up in `ink2`, so the whole row steps forward (on
    /// paper the star has no halo to find it by); the pointer lifts a title to `ink` at once (no
    /// fade: a sweep down the list must not leave a trail, and selection moves by keyboard as
    /// often as by click).
    private struct SessionLedgerRow: View {
        let live: Bool
        let title: String
        let trailing: String
        let meta: String?
        let selected: Bool
        let accessibility: String
        let action: () -> Void
        @Environment(AppModel.self) private var model
        @Environment(\.theme) private var theme
        @State private var hovering = false

        /// The title line's height at 13 pt, which the star is centred in.
        private static let titleLine: CGFloat = 16

        var body: some View {
            let enabled = live || !model.isActive
            Button(action: action) {
                HStack(alignment: .top, spacing: 0) {
                    ZStack {
                        if selected { StarMark() }
                    }
                    .frame(width: 8, height: Self.titleLine)
                    .padding(.leading, SidebarView.slotCenter - 4)
                    .padding(.trailing, SidebarView.textColumn - SidebarView.slotCenter - 4)
                    VStack(alignment: .leading, spacing: 3) {
                        CrossfadeText(text: title, font: LLFont.body,
                                      color: live || selected || (hovering && enabled) ? theme.ink : theme.ink2,
                                      alignment: .leading)
                            .frame(height: Self.titleLine)
                        HStack(alignment: .firstTextBaseline, spacing: LLMetrics.space(2)) {
                            // The clock leaves at once and the summary fades in (same slot, same height).
                            ZStack(alignment: .leading) {
                                if let meta {
                                    Text(meta).font(LLFont.label.monospacedDigit()).foregroundStyle(selected ? theme.ink2 : theme.ink3)
                                        .lineLimit(1).truncationMode(.tail)
                                        .transition(LLMotion.appear)
                                } else {
                                    // A leaf, so the once-a-second tick repaints one Text, not the
                                    // sidebar; monospaced digits, so it never jitters.
                                    SessionClock(color: theme.ink3)
                                        .transition(LLMotion.appear)
                                }
                            }
                            Spacer(minLength: 0)
                            CrossfadeText(text: trailing, font: LLFont.label, color: theme.ink3)
                        }
                    }
                }
                .padding(.trailing, SidebarView.trailingInset)
                .padding(.vertical, LLMetrics.space(2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
            }
            .buttonStyle(LedgerPressStyle())
            .disabled(!enabled)
            .onHover { hovering = $0 }
            .overlay(alignment: .leading) {
                NowMark(visible: live)
                    .padding(.vertical, LLMetrics.space(2))
                    .padding(.leading, SidebarView.slotCenter - 1)
            }
            .accessibilityLabel(accessibility)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(live ? "查看实时字幕" : model.isActive ? "结束当前会话后可回看记录" : "在主窗口回看这次会话")
            .help(!enabled ? "结束当前会话后可回看记录" : accessibility)
        }
    }

    /// A row answers a press by dimming while held, instantly, like a menu row.
    private struct LedgerPressStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}
