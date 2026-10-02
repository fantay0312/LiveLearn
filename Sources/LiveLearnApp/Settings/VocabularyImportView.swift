import SwiftUI
import AppKit
import CloudEngine

/// Compact dictionary composer: direct input first; batch details only appear when needed.
///
/// Round 12: the sheet speaks the three action grammars — 导入文件 and 取消 are words, the one
/// commit (添加 N 条) is the still stellar capsule — and the input is a well in the ground's ink
/// rather than an outlined box. Preview rows carry the same type glyph as the list (a point, or a
/// binary star for a fixed translation) instead of an arrow column.
struct VocabularyImportView: View {
    @Binding var text: String
    let library: VocabularyLibrary
    var fileName: String? = nil
    var fileError: String? = nil
    var engineNote = ""
    let onImport: (VocabularyImportReport) -> Void
    let onCancel: () -> Void
    let onChooseFile: () -> Void
    let onLoadFile: (URL) -> Void
    var previewExpanded = false
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var report: VocabularyImportReport?
    @State private var analyzedText = ""
    @State private var analyzedLibrary = VocabularyLibrary()
    @State private var showingPreview = false
    @State private var showingIssues = false
    @State private var showingHelp = false
    @State private var dropTargeted = false
    @State private var editing = false
    @State private var inputFocused = false
    @State private var inputHovered = false

    static let width: CGFloat = 480
    private static let padding: CGFloat = 24

    private var hasInput: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var currentReport: VocabularyImportReport? {
        if staticRender { return library.previewImport(text) }
        return analyzedText == text && analyzedLibrary == library ? report : nil
    }
    private var editorHeight: CGFloat {
        CGFloat(min(132, max(48, 28 + text.components(separatedBy: .newlines).count * 18)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Text("添加到词库").font(LLFont.title).foregroundStyle(theme.ink)
                Spacer()
                Button { showingHelp.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 13))
                }
                .buttonStyle(GlyphButtonStyle(tint: theme.ink3, flush: .trailing))
                .accessibilityLabel("词汇格式与生效说明")
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("每行一个词；固定译法写成「原文=译文」，也可粘贴表格的两列。")
                        Text("文件支持 TXT、TSV 和 LiveLearn JSON 备份，最大 256 KB。")
                        if !engineNote.isEmpty { Text(engineNote) }
                    }
                    .font(LLFont.body).foregroundStyle(theme.ink2)
                    .padding(20).frame(width: 320)
                    .background(theme.surface)
                }
            }
            input
            if let fileError {
                Text(fileError)
                    .font(LLFont.label).foregroundStyle(theme.brick)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hasInput {
                importFeedback
            }
            HStack(spacing: 16) {
                Button(action: onChooseFile) {
                    Label("导入文件", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(TextButtonStyle(flush: true))
                .help("选择 TXT、TSV 或词汇备份 JSON，也可以将文件拖入输入框")
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(TextButtonStyle(flush: true))
                    .keyboardShortcut(.escape, modifiers: [])
                Button(currentReport.map { $0.added.isEmpty ? "添加词汇" : "添加 \($0.added.count) 条" } ?? "添加词汇") {
                    guard fileError == nil, let report = currentReport, !report.added.isEmpty else { return }
                    onImport(report)
                }
                .buttonStyle(CompactCapsuleButtonStyle())
                .disabled(fileError != nil || currentReport?.added.isEmpty != false)
                .keyboardShortcut(.return, modifiers: .command)
                .help("确认添加 · ⌘↩")
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .background(theme.surface)
        .animation(LLMotion.status(reduceMotion), value: showingPreview)
        .animation(LLMotion.status(reduceMotion), value: showingIssues)
        .task {
            guard !staticRender else { return }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            editing = true
        }
        .task(id: ImportInput(text: text, library: library)) {
            guard !staticRender else { return }
            let input = ImportInput(text: text, library: library)
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            let next = await Task.detached(priority: .userInitiated) { input.library.previewImport(input.text) }.value
            guard !Task.isCancelled else { return }
            report = next
            analyzedText = input.text
            analyzedLibrary = input.library
        }
        .onChange(of: fileName) { _, name in if name != nil { showingPreview = true } }
    }

    /// The `QuietField` grammar at text-area size: a well of `ground` on the `surface` sheet whose
    /// edge turns `ink2` while the text has focus or a file is held over it (and lifts halfway
    /// under the pointer). At rest the edge is a hairline on paper, where the well is barely
    /// darker than the sheet, and clear in the dark, where the step from sheet to black is the
    /// edge and a brighter line would outline the well — except under Increase Contrast, where
    /// that 1.1:1 step is no edge and the lifted hairline (≈ 2.5:1) draws it, as `QuietField`
    /// does. Colour only; the well never moves.
    private var input: some View {
        let shape = RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous)
        return ZStack(alignment: .topLeading) {
            if staticRender {
                ScrollContainer {
                    Text(text).font(.system(size: 15)).foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            } else {
                VocabularyTextInput(text: $text, color: NSColor(theme.ink), placeholderColor: NSColor(theme.ink3),
                                    requestFocus: editing, onFocusChange: { inputFocused = $0 })
            }
            if text.isEmpty && staticRender {
                Text("添加新词，或粘贴多行词汇")
                    .font(.system(size: 15)).foregroundStyle(theme.ink3)
                    .padding(12).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(height: editorHeight)
        .background(theme.ground, in: shape)
        .overlay(shape.strokeBorder(inputEdge, lineWidth: 1))
        .modifier(VocabularyDropTarget(targeted: $dropTargeted, onLoad: onLoadFile))
        .clipShape(shape)
        .onHover { inputHovered = $0 }
        .animation(LLMotion.hover(reduceMotion), value: inputFocused)
        .animation(LLMotion.hover(reduceMotion), value: inputHovered)
    }

    private var inputEdge: Color {
        if dropTargeted || inputFocused { return theme.ink2 }
        if inputHovered { return theme.ink3.opacity(theme.raisesContrast ? 0.8 : 0.5) }
        return theme.isDark && !theme.raisesContrast ? .clear : theme.hairline
    }

    @ViewBuilder
    private var importFeedback: some View {
        if let report = currentReport {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    disclosure(showingPreview ? "收起预览" : "预览 \(report.added.count) 条", open: showingPreview || (staticRender && previewExpanded),
                               color: theme.ink2) { showingPreview.toggle() }
                    if report.duplicates > 0 {
                        Text("跳过 \(report.duplicates) 条重复").foregroundStyle(theme.ink3)
                    }
                    Spacer(minLength: 0)
                    if !report.issues.isEmpty {
                        disclosure("\(report.issues.count) 项需处理", open: showingIssues || report.added.isEmpty,
                                   color: theme.brick) { showingIssues.toggle() }
                    }
                }
                .font(LLFont.label)
                if showingPreview || (staticRender && previewExpanded) {
                    previewRows(report.added)
                }
                if showingIssues || (report.added.isEmpty && !report.issues.isEmpty) {
                    ScrollContainer {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                Text(issue).font(LLFont.label).foregroundStyle(theme.brick)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(height: min(100, CGFloat(report.issues.count) * 38))
                }
                if !report.issues.isEmpty && !report.added.isEmpty {
                    Text("仅添加有效词条，已有译法不会被覆盖。")
                        .font(LLFont.label).foregroundStyle(theme.ink2)
                } else if report.added.isEmpty && report.duplicates > 0 {
                    Text("这些词汇已经在词库中。").font(LLFont.label).foregroundStyle(theme.ink2)
                }
            }
        } else {
            Text("正在检查词汇…").font(LLFont.label).foregroundStyle(theme.ink3)
        }
    }

    /// A word that shows or hides the rows under it, with the paper menu's small chevron turned
    /// down while they are open — so a count with nothing under it reads as closed, not missing.
    private func disclosure(_ title: String, open: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(theme.ink3)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(color)
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
    }

    /// The rows that would be added: the type glyph in a gutter, the word, and a fixed
    /// translation in a column set 16 pt past the longest such word (at most 45 % of the row).
    private func previewRows(_ added: [VocabularyItem]) -> some View {
        let row = Self.width - Self.padding * 2 - VocabularyPageMetrics.typeGutter
        let column = VocabularyPageMetrics.translationColumn(
            widest: VocabularyPageMetrics.widestGlossaryWord(in: added, font: .systemFont(ofSize: 13)), rowWidth: row, gap: 16)
        return ScrollContainer {
            ImportPreviewRows {
                ForEach(added) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        VocabularyKindMark(kind: item.kind)
                            .frame(width: VocabularyPageMetrics.typeGutter, alignment: .leading)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        // A hot word has the whole row; a pair puts its translation on the column.
                        Text(item.source).foregroundStyle(theme.ink)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: item.kind == .glossary ? column : nil, alignment: .leading)
                        if item.kind == .glossary {
                            Text(item.target).foregroundStyle(theme.ink2)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(LLFont.body)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                }
            }
        }
        .frame(height: min(120, CGFloat(max(1, added.count)) * 30))
    }

    private struct ImportInput: Equatable, Sendable {
        let text: String
        let library: VocabularyLibrary
    }
}

private struct VocabularyDropTarget: ViewModifier {
    @Environment(\.staticRender) private var staticRender
    @Binding var targeted: Bool
    let onLoad: (URL) -> Void

    func body(content: Content) -> some View {
        if staticRender { content }
        else {
            content.dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
                onLoad(url)
                return true
            } isTargeted: { targeted = $0 }
        }
    }
}

private struct ImportPreviewRows<Content: View>: View {
    @Environment(\.staticRender) private var staticRender
    @ViewBuilder var content: () -> Content
    var body: some View {
        if staticRender { VStack(alignment: .leading, spacing: 0) { content() } }
        else { LazyVStack(alignment: .leading, spacing: 0) { content() } }
    }
}

struct VocabularyStarterPack: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let text: String
    var count: Int { text.split(separator: "\n").count }
    /// The pack's first words, as a line of the pack page ("SwiftUI · Kubernetes · …"): the
    /// source side of each entry, so a reader sees what the pack holds before previewing it.
    var sample: String {
        let words = text.split(separator: "\n").map { line in
            line.split(separator: "=", maxSplits: 1).first.map(String.init) ?? String(line)
        }
        return words.prefix(5).joined(separator: " · ") + (words.count > 5 ? " …" : "")
    }

    static let all: [Self] = [
        Self(id: "technology", title: "技术交流", subtitle: "开发、架构与技术分享", text: """
        SwiftUI
        Kubernetes
        GitHub
        API
        machine learning=机器学习
        latency=延迟
        deployment=部署
        rollback=回滚
        """),
        Self(id: "meetings", title: "产品会议", subtitle: "需求讨论、项目进度与复盘", text: """
        roadmap=路线图
        milestone=里程碑
        deliverable=交付物
        stakeholder=利益相关方
        action item=待办事项
        retrospective=回顾会议
        """),
        Self(id: "learning", title: "课程学习", subtitle: "讲座、研究方法与课堂笔记", text: """
        hypothesis=假设
        methodology=研究方法
        literature review=文献综述
        case study=案例研究
        peer review=同行评审
        syllabus=课程大纲
        """)
    ]
}
