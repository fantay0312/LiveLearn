import SwiftUI
import AppKit

/// A choice on paper (§5.1, 0.4): a text label with a small chevron that opens a sheet of rows
/// under it. The sheet is our own window, not the system menu, so the list is the same paper
/// as the rest of the app: the floating material (`floatingPaper`), rows in `ink2` that lift to
/// `ink` on a quiet tint under the pointer, the chosen row marked with the star point
/// (`StarMark`, round 12) and an unticked check row with an empty ring in its place. Items are
/// data rather than views, so the keyboard can walk them (↑ ↓, ← → between columns, ⏎, Esc).
///
/// One column is the usual menu. Two columns make a paired choice (源语言 | 目标语言): a pick in
/// any column but the last keeps the sheet open, a pick in the last closes it. Check rows keep
/// the sheet open too, so several applications can be ticked in one visit.
///
/// The item closure runs inside the sheet's own body, so anything it reads from the model is
/// observed: a ticked application shows its tick at once, a changed source language re-lists
/// the targets. In previews the label renders as plain text.
struct PaperMenuItem: Identifiable {
    enum Kind { case row, check, section, divider }

    var id: String
    let kind: Kind
    var title = ""
    /// A second fact at the right of the row, in `ink3`: "系统默认", "626 MB · 已安装", "正在发声".
    var detail: String?
    /// A single-choice row states whether it is the chosen one; a plain action row says nothing.
    var selected: Bool?
    var enabled = true
    var tint: Color?
    var keepsOpen = false
    var action: (() -> Void)?

    var isInteractive: Bool { (kind == .row || kind == .check) && enabled }

    static func row(_ title: String, id: String? = nil, detail: String? = nil, selected: Bool? = nil, enabled: Bool = true,
                    tint: Color? = nil, keepsOpen: Bool = false, action: @escaping () -> Void) -> PaperMenuItem {
        PaperMenuItem(id: id ?? "row:" + title, kind: .row, title: title, detail: detail, selected: selected, enabled: enabled,
                      tint: tint, keepsOpen: keepsOpen, action: action)
    }

    /// A tick that can be on together with others; the sheet stays open.
    static func check(_ title: String, id: String? = nil, detail: String? = nil, on: Bool, enabled: Bool = true,
                      action: @escaping () -> Void) -> PaperMenuItem {
        PaperMenuItem(id: id ?? "check:" + title, kind: .check, title: title, detail: detail, selected: on, enabled: enabled,
                      keepsOpen: true, action: action)
    }

    static func section(_ title: String) -> PaperMenuItem {
        PaperMenuItem(id: "section:" + title, kind: .section, title: title)
    }

    static func divider(_ id: String = "divider") -> PaperMenuItem {
        PaperMenuItem(id: "divider:" + id, kind: .divider)
    }
}

struct PaperMenuColumn {
    var title: String?
    var items: [PaperMenuItem]

    init(title: String? = nil, items: [PaperMenuItem]) {
        self.title = title
        // Ids must be unique inside a column; a second divider or a repeated title gets its place.
        var seen = Set<String>()
        self.items = items.enumerated().map { i, item in
            var item = item
            if !seen.insert(item.id).inserted {
                item.id += "#\(i)"
                seen.insert(item.id)
            }
            return item
        }
    }

    /// Whether the rows reserve a column for the star point.
    var hasMarks: Bool { items.contains { ($0.kind == .row && $0.selected != nil) || $0.kind == .check } }
}

struct PaperChoiceRow<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(LLFont.body)
            Spacer(minLength: 8)
            PaperMenu(title: title(selection), help: help ?? label) {
                options.map { value in
                    .row(title(value), id: String(reflecting: value), selected: selection == value) { selection = value }
                }
            }.frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

struct PaperMenu: View {
    let title: String
    var font: Font = LLFont.body
    var color: Color? = nil
    var help: String? = nil
    /// A bare SF Symbol instead of the title and chevron (the vocabulary rail's "···"): the
    /// glyph grammar, `ink2` lifting to `ink`, in a 28 pt hit. `title` stays the VoiceOver value.
    var glyph: String? = nil
    let columns: () -> [PaperMenuColumn]
    @Environment(\.staticRender) private var staticRender
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsInteractionEnabled) private var inSettings
    @State private var open = false
    @State private var hovering = false
    @State private var anchor = PaperMenuAnchor()

    init(title: String, font: Font = LLFont.body, color: Color? = nil, help: String? = nil, glyph: String? = nil,
         items: @escaping () -> [PaperMenuItem]) {
        self.title = title
        self.font = font
        self.color = color
        self.help = help
        self.glyph = glyph
        self.columns = { [PaperMenuColumn(items: items())] }
    }

    init(title: String, font: Font = LLFont.body, color: Color? = nil, help: String? = nil, columns: @escaping () -> [PaperMenuColumn]) {
        self.title = title
        self.font = font
        self.color = color
        self.help = help
        self.columns = columns
    }

    var body: some View {
        if staticRender {
            label
        } else {
            // The anchor hugs the text (the sheet opens 4pt under it); the hit area reaches 4pt
            // above and below (≥ 24pt, §11) without moving the label in its row.
            Button {
                toggle()
            } label: {
                label
                    .background(PaperMenuAnchorView(anchor: anchor))
                    .padding(.vertical, inSettings ? 8 : 4)
                    .background {
                        if inSettings {
                            SettingsInteractionLight(color: theme.ink, active: enabled && (hovering || open), pressed: false)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .padding(.vertical, inSettings ? -8 : -4)
            .onHover { hovering = $0 }
            .animation(LLMotion.hover(reduceMotion), value: hovering)
            .animation(LLMotion.hover(reduceMotion), value: open)
            .help(help ?? title)
            .accessibilityAddTraits(.isButton)
            // The name is what the control chooses (from `help`), the value is the choice.
            .accessibilityLabel(help ?? title)
            .accessibilityValue(title)
            .accessibilityHint("打开选项")
            .onDisappear { if open { PaperMenuPresenter.shared.dismiss(animated: false) } }
        }
    }

    /// The text and a 7.5pt chevron; the text darkens to `ink` while the sheet is open or the
    /// pointer is over it. A custom color (the accent for a pending choice) is left alone. The
    /// chevron lifts from `ink3` to `ink2` at the same moment, so a label already written in
    /// `ink` (a value the active editor's draft changed) still answers the pointer. With a
    /// `glyph`, the bare symbol on the trailing edge of its 28 pt hit, lifting the same way.
    private var label: some View {
        let base = color ?? theme.ink
        let active = hovering || open
        let lifted = (color == nil || color == theme.ink2 || color == theme.ink3) && active
        return Group {
            if let glyph {
                Image(systemName: glyph).font(.system(size: 13))
                    .foregroundStyle(active ? theme.ink : theme.ink2)
                    .frame(minWidth: 28, minHeight: 28, alignment: .trailing)
            } else {
                HStack(spacing: 3) {
                    titleText.font(font).foregroundStyle(lifted ? theme.ink : base).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(active ? theme.ink2 : theme.ink3)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }

    /// A direction ("中文 → 英语", `StatusCopy.direction`) writes its arrow in `ink3`, so the two
    /// language names carry the pair and the arrow reads as punctuation between them.
    private var titleText: Text {
        let parts = title.components(separatedBy: " → ")
        guard parts.count == 2 else { return Text(title) }
        return Text(parts[0]) + Text(" → ").foregroundStyle(theme.ink3) + Text(parts[1])
    }

    private func toggle() {
        guard enabled else { return }
        if open {
            PaperMenuPresenter.shared.dismiss()
            return
        }
        guard let view = anchor.view else { return }
        open = true
        PaperMenuPresenter.shared.present(anchor: view, environment: environment, columns: columns) {
            open = false
        }
    }
}

/// Where the label is on screen: a zero-size AppKit view under it, asked for its window and
/// frame the moment the sheet opens.
final class PaperMenuAnchor {
    weak var view: NSView?
}

private struct PaperMenuAnchorView: NSViewRepresentable {
    let anchor: PaperMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// What the presenter and the sheet share while one menu is open.
@MainActor
@Observable
final class PaperMenuSession {
    var columns: () -> [PaperMenuColumn]
    private var highlightedItem: (column: Int, id: String)?
    var highlight: (column: Int, index: Int)? {
        get {
            guard let highlightedItem else { return nil }
            let cols = columns()
            guard cols.indices.contains(highlightedItem.column),
                  let index = cols[highlightedItem.column].items.firstIndex(where: { $0.id == highlightedItem.id && $0.isInteractive }) else { return nil }
            return (highlightedItem.column, index)
        }
        set {
            guard let newValue else { highlightedItem = nil; return }
            let cols = columns()
            guard cols.indices.contains(newValue.column), cols[newValue.column].items.indices.contains(newValue.index) else { highlightedItem = nil; return }
            highlightedItem = (newValue.column, cols[newValue.column].items[newValue.index].id)
        }
    }
    let activate: (PaperMenuItem) -> Void

    init(columns: @escaping () -> [PaperMenuColumn], activate: @escaping (PaperMenuItem) -> Void) {
        self.columns = columns
        self.activate = activate
    }

    func isHighlighted(_ column: Int, _ index: Int) -> Bool {
        highlight?.column == column && highlight?.index == index
    }

    /// The highlighted item's id, so the sheet can scroll a keyboard highlight into view.
    var highlightID: String? {
        guard let highlight else { return nil }
        let cols = columns()
        guard highlight.column < cols.count, highlight.index < cols[highlight.column].items.count else { return nil }
        return cols[highlight.column].items[highlight.index].id
    }

    /// ↑ / ↓ inside the column, skipping sections and dividers; from nothing, ↓ starts at the top.
    func move(by delta: Int) {
        let cols = columns()
        guard !cols.isEmpty else { return }
        let column = min(highlight?.column ?? 0, cols.count - 1)
        let items = cols[column].items
        let interactive = items.indices.filter { items[$0].isInteractive }
        guard !interactive.isEmpty else { return }
        if let current = highlight?.index, let pos = interactive.firstIndex(of: current) {
            let next = min(max(pos + delta, 0), interactive.count - 1)
            highlight = (column, interactive[next])
        } else {
            highlight = (column, delta > 0 ? interactive.first! : interactive.last!)
        }
    }

    /// ← / → to the neighbouring column, landing on its chosen row, else its first row.
    func moveColumn(by delta: Int) {
        let cols = columns()
        guard cols.count > 1 else { return }
        land(on: min(max((highlight?.column ?? 0) + delta, 0), cols.count - 1))
    }

    /// Opened from the keyboard: land on the first column's chosen row, else its first row,
    /// so ↓ continues from the choice instead of from the top.
    func highlightChosen() { land(on: 0) }

    private func land(on column: Int) {
        let cols = columns()
        guard column < cols.count else { return }
        let items = cols[column].items
        let chosen = items.firstIndex { $0.isInteractive && $0.selected == true }
        let first = items.firstIndex { $0.isInteractive }
        if let index = chosen ?? first { highlight = (column, index) }
        else { highlight = nil }
    }

    func activateHighlighted() {
        guard let highlight else { return }
        let cols = columns()
        guard highlight.column < cols.count, highlight.index < cols[highlight.column].items.count else { return }
        let item = cols[highlight.column].items[highlight.index]
        guard item.isInteractive else { return }
        activate(item)
    }
}

/// The sheet itself: one or more columns of rows on the floating material (`floatingPaper`:
/// top-lit and shadowless in the dark, paper with one soft shadow in the light). A column taller
/// than the cap scrolls.
///
/// Everything sits on one 26 pt grid (round 12): a row, a column header and a section label
/// each take one whole slot, and so does a divider in a paired sheet, so the two columns of
/// 源语言 | 目标语言 keep shared baselines when read across (a half-row divider under 自动识别
/// used to push the whole left column 11 pt off its neighbour). Column headers and section
/// labels differ in ink and weight — a header names the column, a section groups rows within it.
struct PaperMenuSheet: View {
    let session: PaperMenuSession
    /// Height the presenter allows a column, so the sheet never runs off the screen.
    var columnHeightCap: CGFloat = 380
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender

    static let shadowPad: CGFloat = 28
    static let rowHeight: CGFloat = 26
    static let inset: CGFloat = 6
    /// The highlight sits `inset` inside the 10pt card, so its own radius is the difference:
    /// nested corners stay concentric instead of pinching.
    static let rowRadius: CGFloat = LLMetrics.Radius.card - inset
    /// Leading pad of every row, header, section label and divider: the mark / text column.
    static let textInset: CGFloat = 10
    /// How far the column rule fades in from each end.
    static let columnRuleFade: CGFloat = 24

    /// Height of the slot an item takes. Only a divider in a single-column sheet is half a
    /// row: there no neighbouring column has baselines to share, and a whole blank row around
    /// one rule would read as a gap in the list.
    static func slotHeight(_ kind: PaperMenuItem.Kind, paired: Bool) -> CGFloat {
        kind == .divider && !paired ? rowHeight / 2 : rowHeight
    }

    var body: some View {
        let columns = session.columns()
        HStack(alignment: .top, spacing: 0) {
            ForEach(columns.indices, id: \.self) { c in
                column(columns[c], index: c, last: c == columns.count - 1, paired: columns.count > 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Self.inset)
        .floatingPaper()
        .padding(Self.shadowPad)
    }

    private func column(_ column: PaperMenuColumn, index: Int, last: Bool, paired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = column.title {
                Text(title)
                    .font(LLFont.labelStrong)
                    .foregroundStyle(theme.ink2)
                    .padding(.horizontal, Self.textInset)
                    .frame(height: Self.rowHeight)
            }
            let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(column.items.enumerated()), id: \.element.id) { i, item in
                    itemView(item, column: index, index: i, marks: column.hasMarks, paired: paired)
                        .id(item.id)
                }
            }
            if staticRender {
                // ImageRenderer draws no scroll views; previews show the column in full.
                rows
            } else {
                // ↑ ↓ from the keyboard keep the highlighted row on screen (anchor nil scrolls
                // only when it is out of view, so the pointer never scrolls the column).
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: columnHeightCap)
                        .onAppear {
                            if let id = session.highlightID, session.highlight?.column == index { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: session.highlightID) { _, id in
                            if let id, session.highlight?.column == index { proxy.scrollTo(id, anchor: nil) }
                        }
                }
            }
        }
        .frame(minWidth: 140, maxWidth: 360, alignment: .leading)
        .padding(.leading, index > 0 ? Self.inset + 1 : 0)
        .padding(.trailing, last ? 0 : Self.inset)
        // Every column takes the tallest one's height (the sheet's HStack is fixed to its ideal
        // height), so the column rule runs the full sheet instead of stopping where a shorter
        // column ends.
        .frame(maxHeight: .infinity, alignment: .top)
        // The column rule is drawn on the column, not laid out beside it: a free-standing
        // vertical hairline has no height of its own and stretched the sheet to whatever the
        // window offered. It fades at both ends, so it belongs to neither column.
        .overlay(alignment: .leading) {
            if index > 0 { FadingRule(axis: .vertical, ends: .both, fade: Self.columnRuleFade) }
        }
    }

    @ViewBuilder
    private func itemView(_ item: PaperMenuItem, column: Int, index: Int, marks: Bool, paired: Bool) -> some View {
        switch item.kind {
        case .section:
            // Sat 1 pt off the bottom of its slot, so it binds to the rows under it (its line
            // ≈ 31 pt under the row above, 21 pt over the row below) instead of floating
            // between two groups.
            Text(item.title)
                .font(LLFont.label)
                .foregroundStyle(theme.ink3)
                .padding(.horizontal, Self.textInset)
                .padding(.bottom, 1)
                .frame(height: Self.slotHeight(.section, paired: paired), alignment: .bottom)
        case .divider:
            // Inset to the mark / text column and fading at its far end, like every rule
            // between rows. In a paired sheet the rule has a whole row to itself, so it is drawn
            // a little stronger: at the usual strength the blank row read as a missing item.
            FadingRule(strength: paired ? 0.8 : 0.55)
                .padding(.horizontal, Self.textInset)
                .frame(height: Self.slotHeight(.divider, paired: paired))
        case .row, .check:
            PaperMenuRow(item: item, marks: marks, highlighted: session.isHighlighted(column, index),
                         onHover: { inside in
                             if inside {
                                 session.highlight = (column, index)
                             } else if session.isHighlighted(column, index) {
                                 session.highlight = nil
                             }
                         },
                         onActivate: { session.activate(item) })
        }
    }
}

/// One row: the mark column (the star point) when the column has marks, the title, the detail
/// in `ink3` at the right. The title rests in `ink2` and is written in `ink` when the row is the
/// chosen one or under the pointer / keyboard — the star is never the only sign of a choice.
/// The highlight is the quiet `fill` (a tint, not a slab) — `fillHover` on the chosen row, whose
/// title is already `ink` and would otherwise answer ↑ ↓ with a 1.1:1 tint alone — 55% while
/// pressed; disabled rows fade to 40%.
private struct PaperMenuRow: View {
    let item: PaperMenuItem
    let marks: Bool
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onActivate: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        let chosen = item.selected == true
        Button(action: onActivate) {
            HStack(spacing: LLMetrics.space(2)) {
                if marks {
                    mark.frame(width: 14, height: 14)
                }
                Text(item.title)
                    .font(LLFont.body)
                    .foregroundStyle(item.tint ?? (chosen || highlighted ? theme.ink : theme.ink2))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail {
                    Spacer(minLength: LLMetrics.space(3))
                    Text(detail)
                        .font(LLFont.label)
                        .foregroundStyle(highlighted ? theme.ink2 : theme.ink3)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, PaperMenuSheet.textInset)
            .frame(height: PaperMenuSheet.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PaperRowStyle(highlighted: highlighted, chosen: chosen))
        .disabled(!item.enabled)
        .onHover { onHover($0) }
        .accessibilityLabel(item.title + (item.detail.map { "，" + $0 } ?? ""))
        .accessibilityAddTraits(item.selected == true ? .isSelected : [])
        .accessibilityValue(item.kind == .check ? (item.selected == true ? "已勾选" : "未勾选") : "")
    }

    /// The highlight moves instantly, like a menu's: it follows the keyboard as often as the
    /// pointer, and a fade would trail behind a pointer sweeping down the rows.
    private struct PaperRowStyle: ButtonStyle {
        let highlighted: Bool
        let chosen: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(highlighted && enabled ? (chosen ? theme.fillHover : theme.fill) : .clear,
                            in: RoundedRectangle(cornerRadius: PaperMenuSheet.rowRadius, style: .continuous))
                .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
        }
    }

    /// One mark for "chosen": the star point, stamped, never faded — on the chosen row of a
    /// single-choice column, whose other rows leave the slot empty, and on every ticked row of
    /// a check column (the sheet stays open on a tick, so stars come and go under the pointer
    /// and several can shine at once). An unticked check row holds an empty ring where its star
    /// would be (`CheckRing`), so a check column says "several of these can be lit" before
    /// anything is ticked, and ticked reads from unticked by shape — a lit point against an
    /// empty ring — not by a 1.4 pt dot or by ink alone, which a hovered row shares. Ticked, a
    /// check row's star is the chosen row's star, so on sight only the ring says a row is a
    /// toggle (a faint ring kept round the lit star crossed its rays and read as ◉ / ⊕). VoiceOver
    /// keeps the difference in words: check rows say 已勾选 / 未勾选, every chosen row is
    /// `.isSelected`.
    @ViewBuilder
    private var mark: some View {
        if item.selected == true {
            StarMark()
        } else if item.kind == .check {
            CheckRing()
        } else {
            Color.clear
        }
    }

    /// The empty slot of an unticked check row: a 6 pt ring, 1 pt `ink3` (`ink2` under Increase
    /// Contrast), never filled — no box, which the user ruled out for ticks (round 4). 6 pt and
    /// not 7 so it sits on whole points in the 14 pt mark column and stays crisp at 1×. An unlit
    /// dot (the first round-12 try) fell to ≈ 1.2 : 1 (dark) and 1.7 : 1 (paper) at 1× and read
    /// as nothing.
    private struct CheckRing: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            Circle()
                .strokeBorder(contrast == .increased ? theme.ink2 : theme.ink3, lineWidth: 1)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        }
    }
}
