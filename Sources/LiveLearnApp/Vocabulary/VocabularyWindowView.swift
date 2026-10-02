import SwiftUI
import AppKit
import CloudEngine
import UniformTypeIdentifiers

enum VocabularyWindowSection: String, CaseIterable, Identifiable {
    case all, hotWords, glossary, corrections, packs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部词汇"
        case .hotWords: return "热词"
        case .glossary: return "术语"
        case .corrections: return "误听修正"
        case .packs: return "场景词包"
        }
    }
    var kind: VocabularyKind? {
        switch self {
        case .hotWords: return .hotWord
        case .glossary: return .glossary
        default: return nil
        }
    }
}

/// Where things sit on the vocabulary page (round 12), in points from the page's leading edge.
/// The rail and the content column share one top line; the list's type glyphs stand on the
/// search magnifier's column and its words on the placeholder's.
enum VocabularyPageMetrics {
    static let railWidth: CGFloat = 184
    /// The rail's columns are the records rail's: the selection slot centred at `slotCentre`,
    /// the words from `railText`, the rag (counts, the header's glyphs) `railTrailing` inside.
    /// Paging 记录 ↔ 词汇 then moves neither the header, the star nor the words.
    @MainActor static let slotCentre = SidebarView.slotCenter
    @MainActor static let railText = SidebarView.textColumn
    @MainActor static let railTrailing = SidebarView.trailingInset
    /// The content column: 16 pt after the rail, 24 pt from the page's trailing edge.
    static let contentLeading: CGFloat = 16
    static let contentTrailing: CGFloat = 24
    /// The top line (rail header, search, 星图 / 列表) and every rail row.
    static let lineHeight: CGFloat = 32
    /// Space above the embedded page's top line: the line centres where the records rail's
    /// header row does, so 词汇 sits on 记录's baseline, which is also the record masthead's.
    @MainActor static let embeddedTop: CGFloat =
        SidebarView.headerTop - (lineHeight - SidebarView.headerRowHeight) / 2
    /// The list's type gutter: glyph centred on the magnifier, word on the placeholder's column.
    static let typeGutter: CGFloat = 22
    /// The reading measure of the list, the corrections and the packs, from the content column's
    /// start: the settings page's. Their rules and row actions end on it, next to the words they
    /// belong to, instead of at the window's edge.
    static let measure = LiveLearnSettingsPage.contentMeasure

    /// Rendered widths of glossary words, by font and entry. A list body or an import preview
    /// asks for the widest word whenever it is rebuilt (a click, a keystroke); each word is set
    /// with CoreText once.
    @MainActor private static var widths: [String: CGFloat] = [:]

    /// The widest word that has a translation, in `font`. Hot words take the whole row and do
    /// not count.
    @MainActor static func widestGlossaryWord(in items: [VocabularyItem], font: NSFont) -> CGFloat {
        // The library holds at most 200 translations; a bound keeps edits from piling up entries.
        if widths.count > 1024 { widths.removeAll(keepingCapacity: true) }
        var widest: CGFloat = 0
        for item in items where item.kind == .glossary {
            let key = "\(font.fontName)|\(font.pointSize)|\(item.raw)"
            let width = widths[key] ?? {
                let measured = ceil((item.source as NSString).size(withAttributes: [.font: font]).width)
                widths[key] = measured
                return measured
            }()
            widest = max(widest, width)
        }
        return widest
    }

    /// Where a list's translations start, measured from its words' column: the widest word that
    /// has a translation (`widestGlossaryWord`) plus `gap`, held between `minimum` and 45 % of the
    /// row — a word and its translation read as one pair, and a long phrase cannot push the
    /// translations out. The page's list and the import preview share it.
    static func translationColumn(widest: CGFloat, rowWidth: CGFloat, gap: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        min(max(widest + gap, minimum), rowWidth * 0.45)
    }
}

/// The shared vocabulary page. Standalone sizing is retained only for isolated previews.
///
/// Round 12: the page is the settings Observatory grammar laid over the sky — a bare rail (the
/// header "词汇", a "+" and a "···" glyph, then words marked by a star point, doubling as the
/// map's legend), and one bare top line over the content (search on a ruled line, 星图 / 列表 as
/// words). No icons, fills, boxes or solid buttons.
struct VocabularyWindowView: View {
    var embedded = false
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var section: VocabularyWindowSection = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var prefersStarMap = true
    @State private var editor: VocabularyEditorDraft?
    @State private var importing = false
    @State private var importText = ""
    @State private var importFileName: String?
    @State private var importError: String?
    @State private var choosingFile = false
    @State private var showingHelp = false
    @State private var notice = ""
    @State private var noticeIsError = false
    @State private var backupURL: URL?
    @State private var undoSnapshot: VocabularyLibrary?
    @State private var undoExpected: VocabularyLibrary?
    @FocusState private var searchFocused: Bool

    var previewSection: VocabularyWindowSection = .all
    var previewQuery = ""
    var previewStarMap = true
    var previewSelectedID: String?
    static let size = CGSize(width: 860, height: 600)
    static let minimumSize = CGSize(width: 680, height: 480)

    private var currentSection: VocabularyWindowSection { staticRender ? previewSection : section }
    private var currentQuery: String { staticRender ? previewQuery : query }
    private var currentSelectedID: String? { staticRender ? previewSelectedID : selectedID }
    private var usesStarMap: Bool { theme.isDark && (staticRender ? previewStarMap : prefersStarMap) }
    private var library: VocabularyLibrary { VocabularyLibrary(hotWords: model.settings.hotWords, glossaryLines: model.settings.glossaryLines) }
    private var items: [VocabularyItem] {
        library.items.filter { (currentSection.kind == nil || $0.kind == currentSection.kind) && $0.matches(currentQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                rail
                VStack(alignment: .leading, spacing: 0) {
                    topLine
                    if !notice.isEmpty { feedback }
                    Group {
                        if currentSection == .packs {
                            starterPacks
                        } else if currentSection == .corrections {
                            VocabularyCorrectionsView(model: model, query: currentQuery, onClearSearch: { updateQuery("") })
                        } else if usesStarMap {
                            VocabularyStarMap(items: items, isSearching: !currentQuery.isEmpty,
                                              isVisible: (!embedded || model.mainPage == .vocabulary) && !importing && editor == nil,
                                              selectedID: staticRender ? .constant(previewSelectedID) : $selectedID, onAdd: { openEditor(nil) },
                                              onClearSearch: { updateQuery("") }, onEdit: openEditor, onImport: { beginImport() },
                                              // RootView sets the session's horizon under this page while a session runs.
                                              yieldsToHorizon: embedded && model.isActive)
                        } else if items.isEmpty {
                            emptyState
                        } else {
                            wordTable
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, embedded ? VocabularyPageMetrics.embeddedTop : 32)
            if !embedded { footer }
        }
        .overlay(alignment: .leading) {
            if embedded {
                // The records rail's divider at this rail's edge: a line of light fading at both
                // ends, from the same height under the wordmark and stopping as far above the dock.
                FadingRule(axis: .vertical, ends: .both, fade: LLMetrics.space(7))
                    .padding(.top, LLMetrics.space(2)).padding(.bottom, LLMetrics.space(5))
                    .padding(.leading, VocabularyPageMetrics.railWidth)
            }
        }
        .frame(minWidth: embedded ? 0 : Self.minimumSize.width, idealWidth: embedded ? nil : Self.size.width, maxWidth: .infinity,
               minHeight: embedded ? 0 : Self.minimumSize.height, idealHeight: embedded ? nil : Self.size.height, maxHeight: .infinity)
        .background(embedded ? Color.clear : theme.ground)
        .background {
            if !staticRender && !embedded { VocabularyWindowBehavior(isPinned: model.settings.vocabularyWindowPinned) }
        }
        .ignoresSafeArea(edges: embedded ? [] : .all)
        .sheet(item: $editor) { draft in
            VocabularyEditor(draft: draft, library: library, onSave: { next in
                let previousIDs = Set(library.items.map(\.id))
                let changed = next.items.first { !previousIDs.contains($0.id) }
                commit(next, message: draft.original == nil ? "已添加词汇" : "已保存修改")
                editor = nil
                query = ""
                if let changed {
                    section = changed.kind == .hotWord ? .hotWords : .glossary
                    selectedID = changed.id
                }
            }, onCancel: { editor = nil })
        }
        .sheet(isPresented: $importing) { importSheet }
        .onAppear { receiveTranslationDraft() }
        .onChange(of: model.translationVocabularyDraft) { _, _ in receiveTranslationDraft() }
        .onChange(of: editor == nil && !importing) { _, available in
            if available { receiveTranslationDraft() }
        }
        .onChange(of: library) { _, next in
            if let expected = undoExpected, expected != next { undoSnapshot = nil; undoExpected = nil }
            if let selectedID, !next.items.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }

    private func receiveTranslationDraft() {
        guard editor == nil, !importing, let draft = model.translationVocabularyDraft else { return }
        section = .glossary
        editor = VocabularyEditorDraft(original: nil, kind: .glossary, source: draft.source, target: draft.target)
        model.translationVocabularyDraft = nil
    }

    // MARK: Rail

    /// The rail: its header on the page's top line, then the sections 12 pt below.
    private var rail: some View {
        let library = self.library
        return VStack(alignment: .leading, spacing: 0) {
            railHeader
            VStack(alignment: .leading, spacing: 0) {
                ForEach(VocabularyWindowSection.allCases) { item in
                    railRow(item, count: railCount(item, in: library))
                }
            }
            .padding(.top, 12)
        }
        .frame(width: VocabularyPageMetrics.railWidth, alignment: .leading)
        .background { if embedded && theme.isDark { skyShield } }
    }

    /// "词汇" at 15/500, and at the rail's rag the add glyph (⌘N) and the "···" menu that holds
    /// the rarer actions — import, export, pin, help — like the records rail's header.
    private var railHeader: some View {
        HStack(spacing: 0) {
            Text("词汇").font(LLFont.heading).foregroundStyle(theme.ink)
                .gesture(WindowDragGesture())
            Spacer(minLength: 8)
            Button { openEditor(nil) } label: { Image(systemName: "plus").font(.system(size: 13)) }
                .buttonStyle(GlyphButtonStyle())
                .accessibilityLabel("添加词汇")
                .keyboardShortcut("n", modifiers: .command)
                .disabled(importing || editor != nil)
                .help("添加热词或固定译法 · ⌘N")
            PaperMenu(title: "更多", help: "更多词库操作", glyph: "ellipsis") { moreItems }
        }
        .padding(.leading, VocabularyPageMetrics.railText).padding(.trailing, VocabularyPageMetrics.railTrailing)
        .frame(height: VocabularyPageMetrics.lineHeight)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
        .popover(isPresented: $showingHelp) { vocabularyHelp }
    }

    private var moreItems: [PaperMenuItem] {
        var items: [PaperMenuItem] = [
            .row("导入词汇…", enabled: !importing && editor == nil) { beginImport() },
            .row("导出词库备份", enabled: !library.items.isEmpty, action: prepareExport)
        ]
        if !embedded {
            items.append(.check("置顶窗口", on: model.settings.vocabularyWindowPinned) {
                model.settings.vocabularyWindowPinned.toggle()
            })
        }
        items += [.divider(), .row("词汇生效说明") { showingHelp = true }]
        return items
    }

    /// One section: its name at 13/400 (`ink2`, `ink` when chosen), no icon, no fill. The slot
    /// left of the name holds only the chosen section's star — in the class hue for 热词 and 术语,
    /// silver for the rest. 热词 and 术语 carry their class glyph (a point, a binary star) at the
    /// rag before the count, so the rail stays the legend of the map's two kinds of star without
    /// a second mark in the slot that means "chosen".
    private func railRow(_ item: VocabularyWindowSection, count: Int?) -> some View {
        let selected = currentSection == item
        return Button { section = item; selectedID = nil; searchFocused = false } label: {
            HStack(spacing: 0) {
                ZStack {
                    Color.clear
                    if selected { StarMark(tint: item.kind.map { VocabularyKindMark.tint($0, theme: theme) }) }
                }
                .frame(width: VocabularyKindMark.side, height: VocabularyKindMark.side)
                .padding(.leading, VocabularyPageMetrics.slotCentre - VocabularyKindMark.side / 2)
                .padding(.trailing, VocabularyPageMetrics.railText - VocabularyPageMetrics.slotCentre - VocabularyKindMark.side / 2)
                Text(item.title).font(LLFont.body)
                Spacer(minLength: 8)
                if let count {
                    HStack(spacing: 6) {
                        // At the list gutter's strength: the rail is the only place the map's
                        // two kinds of star are taught.
                        if let kind = item.kind { VocabularyKindMark(kind: kind) }
                        Text("\(count)").font(LLFont.timestamp).foregroundStyle(theme.ink3)
                    }
                }
            }
            .padding(.trailing, VocabularyPageMetrics.railTrailing)
            .frame(height: VocabularyPageMetrics.lineHeight)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: LLMetrics.Radius.control))
        }
        .buttonStyle(RailRowStyle(selected: selected, dark: theme.isDark, anchor: .leading))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The rail's own patch of ground (dark, in the main window). The sky's stars pass behind
    /// the page, and in the rail one resting a few points from the 热词 point turns it into the
    /// binary (术语) glyph, or stands as a stray bullet before a count, where the rail doubles as
    /// the map's legend and shape is the type. The ground colour is invisible on the ground; it
    /// reaches 12 pt past the rail's first and last line and fades out at those edges and at the
    /// rail's own, so no star is cut. Static.
    private var skyShield: some View {
        theme.ground
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 12)
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                }
            }
            .padding(.vertical, -12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The count at the rail's rag, when there is something to count: the library's sections and
    /// pending corrections. The packs are a fixed catalogue, so they carry none.
    private func railCount(_ section: VocabularyWindowSection, in library: VocabularyLibrary) -> Int? {
        let count: Int
        switch section {
        case .all: count = library.items.count
        case .hotWords, .glossary: count = library.items.filter { $0.kind == section.kind }.count
        case .corrections: count = model.vocabularyCandidateCount
        case .packs: return nil
        }
        return count > 0 ? count : nil
    }

    // MARK: Top line

    /// Search on its ruled line, then 星图 / 列表 as two words at the rag (dark, word sections).
    /// An empty library has nothing to search or to view two ways: its word sections show
    /// neither until the first word arrives, and the line keeps its height so the rail header
    /// does not move.
    private var topLine: some View {
        let wordSection = currentSection != .packs && currentSection != .corrections
        let emptyLibrary = wordSection && library.items.isEmpty && currentQuery.isEmpty
        return HStack(spacing: 16) {
            if currentSection != .packs && !emptyLibrary {
                BareSearchField(placeholder: searchPlaceholder, text: Binding(get: { currentQuery }, set: { updateQuery($0) }),
                                accessibilityName: "搜索词汇", focus: $searchFocused)
                    .frame(maxWidth: 340)
                    .background {
                        Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                            .disabled(importing || editor != nil).hidden().accessibilityHidden(true)
                    }
            }
            Spacer(minLength: 0)
            if theme.isDark && wordSection && !emptyLibrary {
                HStack(spacing: 0) {
                    presentationWord("星图", selected: usesStarMap) { prefersStarMap = true }
                    presentationWord("列表", selected: !usesStarMap) { prefersStarMap = false }
                }
                // The words' 10 pt hit padding hangs past the rag, so 列表 ends on it.
                .padding(.trailing, -10)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(height: VocabularyPageMetrics.lineHeight)
        .padding(.leading, VocabularyPageMetrics.contentLeading).padding(.trailing, VocabularyPageMetrics.contentTrailing)
    }

    /// A view choice as a bare word (the settings sub-tab grammar): `ink` with the star stamped
    /// under it when chosen, `ink2` otherwise; weight never changes.
    private func presentationWord(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(LLFont.body)
                .starMarked(selected)
                .padding(.horizontal, 10)
                .frame(height: VocabularyPageMetrics.lineHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailRowStyle(selected: selected, dark: theme.isDark))
        .accessibilityLabel("词汇" + title + "视图")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// User search clears selection; save/import may clear the query and reveal a new selection
    /// in the same update, without a deferred onChange erasing that intentional selection.
    private func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        selectedID = nil
    }

    private var searchPlaceholder: String { currentSection == .corrections ? "搜索原句或候选" : "搜索词汇或译法" }

    // MARK: List

    /// Rows on the ground with fading rules, on the page's measure; the last 32 pt fade out before
    /// the dock instead of being cut by it. Every translation starts on one column set just past
    /// the widest word (at least 160 pt, at most 45 % of the row). The first word shares the first
    /// rail name's baseline. The words are measured here, outside the reader, so a live resize
    /// only re-clamps the column.
    private var wordTable: some View {
        let items = self.items
        let widest = VocabularyPageMetrics.widestGlossaryWord(in: items, font: .systemFont(ofSize: 13, weight: .medium))
        return GeometryReader { geometry in
            let row = min(geometry.size.width - VocabularyPageMetrics.contentLeading - VocabularyPageMetrics.contentTrailing,
                          VocabularyPageMetrics.measure) - VocabularyPageMetrics.typeGutter
            let column = VocabularyPageMetrics.translationColumn(widest: widest, rowWidth: row,
                                                                 gap: VocabularyWindowRow.translationGap, minimum: 160)
            ScrollContainer {
                VocabularyWindowRows {
                    ForEach(items) { item in
                        VocabularyWindowRow(item: item, selected: currentSelectedID == item.id, translationColumn: column,
                                            onSelect: { selectedID = item.id }, onEdit: { openEditor(item) }, onRemove: { remove(item) })
                    }
                }
                .frame(maxWidth: VocabularyPageMetrics.contentLeading + VocabularyPageMetrics.measure + VocabularyPageMetrics.contentTrailing,
                       alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 5).padding(.bottom, 32)
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 32)
                }
            }
        }
    }

    /// No words yet, or none matching: the page's opening line at 24/400 on the content column,
    /// one sentence, and the way forward as text actions — no icon, no plate.
    private var emptyState: some View {
        let searching = !currentQuery.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Text(searching ? "没有匹配项" : "暂无词汇").font(LLFont.display).foregroundStyle(theme.ink)
            Text(searching ? "试试更短的关键词，或清除搜索查看全部词汇。" : "添加常用名称或固定译法，方便识别与翻译。")
                .font(LLFont.body).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                if searching {
                    Button("清除搜索") { updateQuery("") }.buttonStyle(TextButtonStyle(flush: true, strong: true))
                } else {
                    Button("添加词汇") { openEditor(nil) }.buttonStyle(TextButtonStyle(flush: true, strong: true))
                    Button("导入文件") { beginImport() }.buttonStyle(TextButtonStyle(flush: true, strong: true))
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.top, 48)
        .padding(.leading, VocabularyPageMetrics.contentLeading)
    }

    // MARK: Packs

    /// Each pack: its name, what it is for, a sample of its words, and 预览 N 条 as a text action
    /// on the name's line, on the page's measure; fading rules between packs. The first name
    /// shares the first rail name's baseline.
    private var starterPacks: some View {
        ScrollContainer {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(VocabularyStarterPack.all) { pack in
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(pack.title).font(LLFont.heading).foregroundStyle(theme.ink)
                            Text(pack.subtitle).font(LLFont.label).foregroundStyle(theme.ink2)
                            Text(pack.sample).font(LLFont.label).foregroundStyle(theme.ink3)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 16)
                        Button("预览 \(pack.count) 条") { beginImport(pack.text) }
                            .buttonStyle(TextButtonStyle(flush: true))
                    }
                    .padding(.top, pack.id == VocabularyStarterPack.all.first?.id ? 14 : 18).padding(.bottom, 18)
                    if pack.id != VocabularyStarterPack.all.last?.id { FadingRule() }
                }
            }
            .frame(maxWidth: VocabularyPageMetrics.measure, alignment: .leading)
            .padding(.leading, VocabularyPageMetrics.contentLeading).padding(.trailing, VocabularyPageMetrics.contentTrailing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Footer, help, notices

    /// Standalone window only: one quiet line. The help is the "···" menu's 词汇生效说明.
    private var footer: some View {
        HStack(spacing: 0) {
            if currentSection != .corrections {
                Text("本机保存 · \(usageStatus)").font(LLFont.label).foregroundStyle(theme.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, VocabularyPageMetrics.railText).padding(.trailing, VocabularyPageMetrics.contentTrailing)
        .frame(height: 38)
    }

    private var vocabularyHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
                    Text(currentSection == .corrections ? "逐处确认" : "词汇怎样生效").font(LLFont.bodyStrong).foregroundStyle(theme.ink)
                    Text(currentSection == .corrections ? "候选仅供判断。确认后立即修订当前句子，不会形成自动替换规则。会话记录是否保存，遵循你的记录设置。" : engineNote).font(LLFont.body).foregroundStyle(theme.ink2)
                    Text("固定译法最多 200 条；导入不会覆盖已有译法。")
                        .font(LLFont.label).foregroundStyle(theme.ink3)
                    Button("前往引擎设置") {
                        showingHelp = false
                        if !embedded { dismissWindow(id: "vocabulary") }
                        model.settings.requestedSettingsTab = .engine
                        UnifiedSettingsPresentation.shared.open()
                    }.buttonStyle(TextButtonStyle(flush: true))
                }
                .padding(20).frame(width: 340).background(theme.surface)
    }

    private var engineNote: String {
        model.blueprint.vocabularyUsageNote
    }

    private var usageStatus: String {
        if currentSection == .corrections { return "确认仅修改这一处" }
        if model.isActive { return "下次会话应用" }
        return "用于识别与翻译"
    }

    private var feedback: some View {
        HStack(spacing: 10) {
            Text(notice).font(LLFont.label).foregroundStyle(noticeIsError ? theme.brick : theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if undoSnapshot != nil { Button("撤销", action: undo).buttonStyle(TextButtonStyle(flush: true)) }
            if let backupURL {
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }.buttonStyle(TextButtonStyle(flush: true))
            }
            Button { notice = ""; backupURL = nil; undoSnapshot = nil; undoExpected = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: .trailing)).accessibilityLabel("关闭操作提示")
        }
        // On the list's measure: 撤销 and ✕ stay beside the sentence they answer.
        .frame(maxWidth: VocabularyPageMetrics.measure)
        .padding(.leading, VocabularyPageMetrics.contentLeading).padding(.trailing, VocabularyPageMetrics.contentTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private var importSheet: some View {
        VocabularyImportView(text: Binding(get: { importText }, set: { importText = $0; importError = nil; importFileName = nil }),
                             library: library, fileName: importFileName, fileError: importError, engineNote: engineNote,
                             onImport: { report in
            commit(report.library, message: "已导入 \(report.added.count) 条词汇\(report.duplicates > 0 ? "，跳过 \(report.duplicates) 条重复项" : "")")
            importing = false
            importText = ""
            importFileName = nil
            importError = nil
            section = .all
            query = ""
            selectedID = report.added.first?.id
        }, onCancel: { importing = false; importError = nil }, onChooseFile: { choosingFile = true }, onLoadFile: loadFile)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .json, .tabSeparatedText]) { result in
            switch result {
            case .success(let url): loadFile(url)
            case .failure(let error): if (error as NSError).code != NSUserCancelledError { importError = "无法读取文件：\(error.localizedDescription)" }
            }
        }
    }

    private func beginImport(_ text: String = "") {
        importText = text; importFileName = nil; importError = nil; notice = ""; importing = true
    }

    private func openEditor(_ item: VocabularyItem?) {
        guard !importing else { return }
        editor = VocabularyEditorDraft(original: item, kind: item?.kind ?? currentSection.kind ?? .hotWord,
                                       source: item?.source ?? "", target: item?.target ?? "")
        notice = ""; backupURL = nil
    }

    private func commit(_ next: VocabularyLibrary, message: String) {
        let previous = library
        guard previous != next else { return }
        undoSnapshot = previous; undoExpected = next
        model.settings.hotWords = next.hotWords
        model.settings.glossaryLines = next.glossaryLines
        notice = message; noticeIsError = false; backupURL = nil
    }

    private func remove(_ item: VocabularyItem) {
        var next = library
        next.remove(item)
        commit(next, message: "已移除「\(item.source)」")
    }

    private func undo() {
        guard let snapshot = undoSnapshot, undoExpected == library else { return }
        model.settings.hotWords = snapshot.hotWords
        model.settings.glossaryLines = snapshot.glossaryLines
        undoSnapshot = nil; undoExpected = nil
        notice = "已撤销上一步操作"; noticeIsError = false
    }

    private func prepareExport() {
        do {
            backupURL = try VocabularyBackupStore.save(library)
            notice = "已保存词库备份"; noticeIsError = false; undoSnapshot = nil; undoExpected = nil
        } catch { notice = "无法导出：\(error.localizedDescription)"; noticeIsError = true }
    }

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= VocabularyLibrary.importByteLimit else { importError = "文件超过 256 KB，请拆分后导入。"; return }
            let data = try Data(contentsOf: url)
            guard data.count <= VocabularyLibrary.importByteLimit, let text = String(data: data, encoding: .utf8) else {
                importError = "请使用不超过 256 KB 的 UTF-8 文本或 LiveLearn JSON 备份。"; return
            }
            importText = text; importFileName = url.lastPathComponent; importError = nil
        } catch { importError = "无法读取文件：\(error.localizedDescription)" }
    }
}

private struct VocabularyWindowRows<Content: View>: View {
    @Environment(\.staticRender) private var staticRender
    @ViewBuilder var content: () -> Content
    var body: some View {
        if staticRender { VStack(spacing: 0) { content() } }
        else { LazyVStack(spacing: 0) { content() } }
    }
}

/// One word: its type glyph in the gutter, the word, its translation on the list's shared column
/// when it has one, and the two glyph actions in `ink3`. The records rail's ladder, weights
/// fixed: the word rests in `ink2` and lifts to `ink` at once under the pointer or keyboard
/// focus (no fade, so a sweep down the list leaves no trail); chosen, the word is `ink`, the
/// translation steps `ink3` → `ink2` and the gutter glyph lights into the star — the mark is
/// never the only sign, and Differentiate Without Color underlines the chosen word. No fill;
/// keyboard focus keeps a visible ink edge.
private struct VocabularyWindowRow: View {
    let item: VocabularyItem
    let selected: Bool
    /// Where the translation starts, from the word's column (`VocabularyPageMetrics.translationColumn`).
    let translationColumn: CGFloat
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
    @State private var hovering = false
    @FocusState private var rowFocused: Bool
    @FocusState private var actionFocus: RowAction?

    private enum RowAction { case edit, remove }

    /// The least air between a word and its translation; a word wider than its column wraps.
    static let translationGap: CGFloat = 24

    /// The row in hand: under the pointer, or keyboard focus on the row or either glyph.
    private var inHand: Bool { hovering || rowFocused || actionFocus != nil }

    private var word: some View {
        Text(item.source).font(LLFont.bodyStrong).foregroundStyle(selected || inHand ? theme.ink : theme.ink2)
            .underline(selected && withoutColor, color: theme.ink)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                VocabularyKindMark(kind: item.kind, lit: selected)
                    .frame(width: VocabularyPageMetrics.typeGutter, alignment: .leading)
                    // The glyph's centre on the middle of the word's letters, 4 pt over the baseline.
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    if item.kind == .glossary {
                        HStack(alignment: .firstTextBaseline, spacing: Self.translationGap) {
                            word.frame(width: max(0, translationColumn - Self.translationGap), alignment: .leading)
                            Text(item.isValid ? item.target : "译法缺失，请编辑")
                                .font(LLFont.body).foregroundStyle(item.isValid ? (selected ? theme.ink2 : theme.ink3) : theme.brick)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // A hot word has the whole row.
                        word.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Shown for the row in hand (pointer, selection, keyboard focus on the row or
                    // on either glyph); a list of resting rows carries no repeated glyphs. They
                    // keep their place. Hidden, they leave the accessibility tree, so the row
                    // itself offers both as VoiceOver actions and in its context menu; keyboard
                    // focus on the row shows them and lets Tab reach them.
                    HStack(spacing: 0) {
                        Button(action: onEdit) { Image(systemName: "pencil") }
                            .focused($actionFocus, equals: .edit)
                            .accessibilityLabel("编辑\(item.source)")
                        Button(action: onRemove) { Image(systemName: "trash") }
                            .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: .trailing))
                            .focused($actionFocus, equals: .remove)
                            .accessibilityLabel("移除\(item.source)")
                    }
                    .font(.system(size: 12))
                    .buttonStyle(GlyphButtonStyle(tint: theme.ink3))
                    .opacity(selected || inHand ? 1 : 0)
                }
            }
            .lineLimit(2).textSelection(.enabled)
            .padding(.vertical, 9)
            FadingRule()
        }
        .overlay(RoundedRectangle(cornerRadius: LLMetrics.Radius.control).strokeBorder(rowFocused ? theme.ink2 : .clear, lineWidth: 1))
        .padding(.leading, VocabularyPageMetrics.contentLeading).padding(.trailing, VocabularyPageMetrics.contentTrailing)
        .contentShape(Rectangle())
        .focusable()
        .focused($rowFocused)
        .onKeyPress(.space) { onSelect(); return .handled }
        .onKeyPress(.return) { onEdit(); return .handled }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.source)
        // The type is drawn only as the gutter glyph (hidden from VoiceOver), so it is spoken here.
        .accessibilityValue(item.kind.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "选择") { onSelect() }
        .accessibilityAction(named: "编辑") { onEdit() }
        .accessibilityAction(named: "移除") { onRemove() }
        .help(item.kind == .hotWord ? item.source : "\(item.source) → \(item.target)")
        .contextMenu {
            Button("编辑", action: onEdit)
            Button("移除", role: .destructive, action: onRemove)
        }
    }
}
