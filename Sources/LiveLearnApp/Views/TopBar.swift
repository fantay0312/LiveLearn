import SwiftUI
import AppKit
import SessionDomain
import SessionStorage

/// The horizon (round 12): the session's transport as the reading page's lower edge. No card,
/// no fill, no stroke — one fading rule across the top, and under it, on the ground: the
/// transport marks in the timestamp gutter, the sound lines from the text column across all the
/// free width, then the toggles, the facts and the status sentence. The transcript above fades
/// into it (`TranscriptView.bottomFade`).
///
/// Idle: title and status only; the start action sits beside session setup below.
/// Active or completed: transport, source waves, and session facts. The middle yields width
/// first so controls and status remain available in compact windows.
struct TopBar: View {
    var availableWidth: CGFloat? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    /// One row of the middle: a lane that runs, or one the next session would open.
    private struct BarRow: Identifiable {
        let id: String
        let label: String
        let live: Bool
        let seed: Float
    }

    /// Height of the horizon's row: the 36 pt transport slots and the 28 pt words sit centred in
    /// it, with the same air above them (under the rule) as below (over the dock).
    static let rowHeight: CGFloat = 48
    /// The transport marks hang in the reading column's timestamp gutter, placed so the right
    /// slot's glyph (the stop square) ends where the timestamps end (gutter − 16 = 56 pt): the
    /// 28 pt slot's centre sits 5 pt inside that edge. Whatever follows starts on the text column.
    private static let marksTrailing = LLMetrics.gutterWidth - LLMetrics.space(4) + (TransportButton.slot.width / 2 - 5)

    /// Row width: measured in the app; derived from the window layout in offscreen previews,
    /// where geometry callbacks do not run.
    private var columnWidth: CGFloat {
        if staticRender {
            return availableWidth ?? ReadingColumn.block
        }
        return width
    }

    /// Below this width the wave labels keep only the source name. The horizon has no inner
    /// padding, so this is the width its contents share: the gutter and its gap (86 pt), a label
    /// with its direction (~100 pt), the wave's 120 pt floor, the toggles and facts (~200 pt
    /// while live; ~300 pt once 保存 / 导出 join them after a session) and the status sentence,
    /// measured, since a failure or a degraded lane says forty characters where "正在听 ·
    /// Safari" says ten. The records page gives the horizon the reading block (712 pt), the
    /// minimum window with the directory open 632 pt. Unknown width (first frame) counts as
    /// narrow so the row can never overflow before it is measured.
    private var compact: Bool {
        columnWidth < (model.currentRecord == nil ? 560 : 660) + statusWidth
    }

    /// The status sentence's width on one line at 13 pt, up to the measure it wraps at.
    private var statusWidth: CGFloat {
        let width = (statusLine as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return min(width.rounded(.up), Self.statusMeasure)
    }

    /// The status sentence — unless the page's recovery note already says exactly that (a
    /// failure the user can fix): then the horizon says only that the session stopped,
    /// and the note keeps the sentence and the action that fixes it. The help keeps the full
    /// sentence either way.
    private var statusLine: String {
        if model.sessionState == .failed, model.recoveryAdvice?.detail == model.statusText { return "已停止" }
        // The sound lines already name every lane, so "正在听 · Safari" beside "Safari · 英语 → 中文"
        // would say the source twice. Only while every lane is heard; `.help` keeps the full text.
        if model.sessionState == .running, !model.isViewingRecord, !model.lanes.isEmpty,
           !model.lanes.contains(where: { $0.capture.state == .sourceIdle }),
           model.statusText.hasPrefix("正在听 · ") { return "正在听" }
        return model.statusText
    }

    /// The status sentence wraps onto a second line past this width instead of pushing the row
    /// past the block's edge or cutting an error short; two 13 pt lines sit inside the row.
    private static let statusMeasure: CGFloat = 320

    var body: some View {
        let rows = barRows
        HStack(spacing: 0) {
            if model.sessionState == .idle {
                Text("新会话").font(LLFont.body).foregroundStyle(theme.ink2)
            } else {
                controls
                    .disabled(model.isReconfiguringSession)
                    .fixedSize()
                    .frame(width: Self.marksTrailing, alignment: .trailing)
                Color.clear.frame(width: ReadingColumn.textInset - Self.marksTrailing)
                // A record being read is named by its masthead, and its route and length are in
                // the masthead's facts: the horizon repeats neither. On the text column it says
                // what the start mark does instead — a bare ▶ beside a record read as "play
                // this record". The mark keeps the label, hint and ⌘↩, so the word is hidden
                // from VoiceOver and skipped by Tab: the mark stays the one stop that starts.
                if model.isViewingRecord {
                    Button("新会话") { model.start() }
                        .buttonStyle(TextButtonStyle(flush: true))
                        .fixedSize()
                        .disabled(!model.canStart)
                        .help(model.canStart ? "开始新会话；⌘↩" : model.startBlocker ?? "开始新会话")
                        .accessibilityHidden(true)
                        .focusable(false)
                } else {
                    if rows.isEmpty {
                        // No lanes and no draft: the title says what is missing.
                        Text(model.sessionTitle)
                            .font(LLFont.body)
                            .foregroundStyle(theme.ink2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                    } else {
                        soundLines(rows)
                            .layoutPriority(-1)
                    }
                }
            }
            if model.sessionState == .idle || model.isViewingRecord || rows.isEmpty {
                Spacer(minLength: LLMetrics.space(2))
            }
            status
                .padding(.leading, LLMetrics.space(4))
                .layoutPriority(1)
        }
        .frame(height: Self.rowHeight)
        .overlay(alignment: .top) {
            FadingRule(ends: .both, fade: LLMetrics.space(7))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    /// The same rule as `sessionTitle`: a session's own lanes while it exists (running, paused,
    /// or finished and still on screen), otherwise the draft. A wave moves only for a lane the
    /// session is listening to right now.
    private var barRows: [BarRow] {
        // Before a session the right side is one word, so the direction always fits.
        let withDirection = !compact || model.sessionState == .idle
        if !model.lanes.isEmpty {
            return model.lanes.enumerated().map { i, lane in
                BarRow(id: lane.id, label: AppModel.laneTitle(lane, withDirection: withDirection),
                       live: model.isRunning && lane.isUploading, seed: Float(i) * 2.1)
            }
        }
        return model.draftLanes.enumerated().map { i, lane in
            BarRow(id: lane.id, label: lane.title(withDirection: withDirection), live: false, seed: Float(i) * 2.1)
        }
    }

    /// One row per lane: label, then the wave across whatever width is left. The label is
    /// the lane's title in small ink at its own width (a fixed label column left a hole of
    /// ~130 pt before a short label's wave); narrow rows keep just the source name. The wave has
    /// a floor width so it is always a line, never a stub, and the label never wraps.
    private func soundLines(_ rows: [BarRow]) -> some View {
        let two = rows.count > 1
        // A grid so both waves start on the same x whatever their labels measure.
        return Grid(alignment: .leading, horizontalSpacing: LLMetrics.space(4), verticalSpacing: two ? 2 : 0) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .font(LLFont.label)
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.label)
                        .gridColumnAlignment(.leading)
                    LaneWave(laneID: row.id, color: theme.ink2, echo: theme.ink3,
                             motion: row.live ? .listening : .still,
                             height: two ? 16 : 22, seed: row.seed)
                        .frame(minWidth: compact ? 44 : 120, maxWidth: .infinity)
                }
                .frame(height: two ? 20 : 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.sessionTitle)
    }

    /// Which marks the bar shows; the four shapes the session can be in from here.
    private enum TransportPhase: Equatable { case idle, starting, paused, running, finishing }

    private var phase: TransportPhase {
        switch model.sessionState {
        case .idle, .completed, .failed: return .idle
        case .preparing, .connecting: return .starting
        case .paused: return .paused
        case .draining, .stopping: return .finishing
        default: return .running
        }
    }

    /// Marks, not boxes, in every state: start (an accent triangle — ice / forest — at the head
    /// of the resting lines), pause (two ink bars), resume (a smaller accent triangle) and stop
    /// (an ink square), so the bar reads as one line of ink beside the sound.
    ///
    /// Two slots, always 60pt together. Before a session the start triangle sits in the right
    /// slot, exactly where the stop square will be, so the head of the sound lines never moves
    /// when a session begins or ends; the marks crossfade in place (150ms) instead of the bar
    /// reflowing. Under Reduce Motion they simply swap. The triangle is drawn 2 pt towards its
    /// point inside its slot; here it moves 4 pt back (the smaller tinted one 1 pt) so its point,
    /// like the square's edge, ends where the timestamps end.
    private var controls: some View {
        let phase = self.phase
        return HStack(spacing: LLMetrics.space(1)) {
            ZStack {
                switch phase {
                case .idle, .starting, .finishing:
                    Color.clear
                case .paused:
                    TransportButton(glyph: .play, help: "继续；⌘⇧P") { model.resume() }
                        .disabled(!model.canPauseOrResume)
                        .transition(LLMotion.fade)
                case .running:
                    TransportButton(glyph: .pause, help: "暂停；⌘⇧P") { model.pause() }
                        .disabled(!model.canPauseOrResume)
                        .transition(LLMotion.fade)
                }
            }
            .frame(width: TransportButton.slot.width, height: TransportButton.slot.height)
            ZStack {
                switch phase {
                case .idle:
                    TransportButton(glyph: .start, help: "开始；⌘↩", shortcut: KeyboardShortcut(.return, modifiers: .command),
                                    hint: model.canStart ? "⌘↩" : model.startBlocker,
                                    tint: startTint) { model.start() }
                        .disabled(!model.canStart)
                        .offset(x: startTint == nil ? -4 : -1)
                        .transition(LLMotion.fade)
                default:
                    TransportButton(glyph: .stop, help: "停止；⌘.") { model.stop() }
                        .disabled(!model.canStop)
                        .accessibilityHint(model.canStop ? "" : "正在收尾，请稍候")
                        .transition(LLMotion.fade)
                }
            }
            .frame(width: TransportButton.slot.width, height: TransportButton.slot.height)
        }
        .animation(LLMotion.status(reduceMotion), value: phase)
    }

    /// The start mark's ink: the accent before a session; `ink2` beside a session that just
    /// finished, where it starts a new one and must not outshine the text; `ink3` beside a
    /// record read back, where its word 新会话 carries it and a solid mark in the word's ink
    /// would be the heaviest thing on the horizon. Both lift to `ink` under the pointer.
    private var startTint: Color? {
        if model.isViewingRecord { return theme.ink3 }
        return model.currentRecord == nil ? nil : theme.ink2
    }

    /// What the status cluster is made of right now; a change fades the new parts in.
    private struct StatusKey: Equatable {
        var active: Bool
        var finished: Bool
        var saved: Bool?
        var gaps: Bool
        var lag: Bool
    }

    /// Tertiary actions, then the facts (lag, gaps, clock), then the status sentence. Clusters
    /// that come and go (保存 / 导出 after a session, the clock during one) fade in and leave at
    /// once; the sentence at the right end stays put. The status is always words (§9.1): no
    /// pulsing symbol beside it — the wave to the left already moves while the lane is heard,
    /// and the sentence says so ("正在听 · Safari", "已暂停 · 未上传").
    private var status: some View {
        let key = StatusKey(active: model.isActive, finished: model.currentRecord != nil && !model.isActive,
                            saved: model.currentRecord?.saved, gaps: model.gapCount > 0, lag: model.lagText != nil)
        return HStack(spacing: LLMetrics.space(4)) {
            actions
            facts
            statusSentence
                .help(model.sessionState == .idle ? model.startBlocker ?? "未开始 · 点击左侧开始，或按 ⌘↩" : model.statusText)
        }
        .animation(LLMotion.status(reduceMotion), value: key)
        .animation(LLMotion.status(reduceMotion), value: model.sessionState)
    }

    /// A sentence that may take two lines: it hugs its words up to `statusMeasure` and wraps past
    /// it, changing as `CrossfadeText` does (the old sentence leaves at once, the new one fades in
    /// over 150ms, the trailing edge stays put).
    private var statusSentence: some View {
        StatusMeasure(width: Self.statusMeasure) {
            CrossfadeText(text: statusLine, font: LLFont.body, color: statusColor, lineLimit: 2)
        }
    }

    /// Two groups, set apart by the cluster's own 16 pt: what can be done with the record
    /// (保存 / 导出) and what the overlay shows (字幕 / 锁定). At one spacing the four words read
    /// as one toolbar.
    @ViewBuilder
    private var actions: some View {
        let finished = model.currentRecord != nil && !model.isActive
        let live = model.isActive || model.sessionState == .completed
        if finished || live {
            HStack(spacing: LLMetrics.space(4)) {
                if let record = model.currentRecord, finished {
                    HStack(spacing: LLMetrics.space(1)) {
                        if !record.saved {
                            Button("保存") { model.save(record) }
                                .buttonStyle(TextButtonStyle())
                                .fixedSize()
                                .help("把这次会话的正文保存到本机记录文件夹")
                                .transition(LLMotion.appear)
                        }
                        PaperMenu(title: "导出", color: theme.ink2, help: "导出为 TXT / Markdown / SRT / WebVTT") { [model] in
                            ExportFormat.allCases.map { format in
                                .row(format.label, id: format.rawValue) { ExportPanel.present(record, format: format, model: model) }
                            }
                        }
                        .padding(.horizontal, 6)
                        .frame(height: LLMetrics.controlHeight)
                        .fixedSize()
                    }
                    .transition(LLMotion.appear)
                }
                if live {
                    overlayControls
                        .transition(LLMotion.appear)
                }
            }
            .transition(LLMotion.appear)
        }
    }

    /// Lag, gaps and the clock, all 11pt monospaced ink3 (§9.1). The clock stays through 已结束
    /// with the final duration, so 字幕 / 锁定 keep their place when a session stops; once the
    /// session is a record, it is the record's own length, the one the rail and the masthead
    /// write. Both read `StatusCopy.clock` ("2:04"). A record read back has no clock here: its
    /// masthead and its rail row already say its length, and nothing shifts, since a record is
    /// only ever opened (`AppModel.showRecord`), never reached by a session ending.
    @ViewBuilder
    private var facts: some View {
        let clock = (model.isActive || model.sessionState == .completed) && !model.isViewingRecord
        let hasFacts = model.lagText != nil || model.gapCount > 0 || clock
        if hasFacts {
            HStack(spacing: LLMetrics.space(2)) {
                if let lag = model.lagText {
                    Text(lag).font(LLFont.timestamp).foregroundStyle(theme.ochre).fixedSize()
                        .transition(LLMotion.appear)
                }
                if model.gapCount > 0 {
                    Text("缺口 \(model.gapCount) 处").font(LLFont.timestamp).foregroundStyle(theme.ink3).fixedSize()
                        .transition(LLMotion.appear)
                }
                if clock {
                    if let record = model.currentRecord {
                        Text(StatusCopy.clock(record.durationNs))
                            .font(LLFont.timestamp).foregroundStyle(theme.ink3).fixedSize()
                            .transition(LLMotion.appear)
                    } else {
                        SessionClock(font: LLFont.timestamp, color: theme.ink3)
                            .transition(LLMotion.appear)
                    }
                }
            }
            .transition(LLMotion.appear)
        }
    }

    /// Two words that are on or off (§9.1, 0.4): "字幕" is written in ink while the overlay is
    /// on screen and fades when it is hidden; "锁定" the same for click-through. Both stay in
    /// place while a session runs, so pressing one never shifts the cluster. Shortcuts live in
    /// the 会话 menu; repeating them here would fire the toggle twice.
    private var overlayControls: some View {
        @Bindable var model = model
        let overlayKey = model.settings.hotKey(for: .toggleOverlay).map { "，全局 \($0.display)" } ?? ""
        let lockKey = model.settings.hotKey(for: .toggleLock).map { "；\($0.display) 在任何应用里都可解锁" } ?? ""
        return HStack(spacing: LLMetrics.space(1)) {
            Toggle("字幕", isOn: $model.overlayVisible)
                .toggleStyle(TextToggleStyle())
                .fixedSize()
                .help((model.overlayVisible ? model.overlayCloseHelp : "显示字幕，不会自动开始或继续会话") + "；⌘⇧H\(overlayKey)")
            Toggle("锁定", isOn: $model.overlayLocked)
                .toggleStyle(TextToggleStyle())
                .fixedSize()
                .help("锁定后字幕正文点击穿透；移到浮层顶部可解锁\(lockKey)")
        }
    }

    private var statusColor: Color {
        switch model.sessionState {
        case .failed: return theme.brick
        case .degraded, .reconnecting: return theme.ochre
        default: return theme.ink2
        }
    }
}

/// Proposes at most `width` to its content and takes the content's own size, so a sentence hugs
/// its words up to the measure and wraps beyond it (a `frame(maxWidth:)` would claim the whole
/// measure even for three words).
private struct StatusMeasure: Layout {
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
