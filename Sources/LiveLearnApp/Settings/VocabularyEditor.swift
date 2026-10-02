import SwiftUI
import CloudEngine

struct VocabularyEditorDraft: Identifiable {
    let id = UUID()
    var original: VocabularyItem?
    var kind: VocabularyKind
    var source: String
    var target: String
}

/// Add or edit one word (round 12): the title at 17/500, the kind as two words with the star,
/// the fields as wells of `ground` on the `surface` sheet (the `QuietField` rule for a field on a
/// sheet), 取消 as a word and the one commit as the still stellar capsule.
struct VocabularyEditor: View {
    @State var draft: VocabularyEditorDraft
    let library: VocabularyLibrary
    let onSave: (VocabularyLibrary) -> Void
    let onCancel: () -> Void
    @Environment(\.theme) private var theme
    @State private var error = ""
    @FocusState private var sourceFocused: Bool
    @FocusState private var targetFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(draft.original == nil ? "添加词汇" : "编辑词汇")
                    .font(LLFont.title).foregroundStyle(theme.ink)
                Spacer()
                TextSegment(options: VocabularyKind.allCases.map { ($0, $0.label) }, selection: $draft.kind)
                    .disabled(draft.original != nil)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(draft.kind == .hotWord ? "热词" : "原文").font(LLFont.label).foregroundStyle(theme.ink2)
                    QuietField(placeholder: draft.kind == .hotWord ? "例如：WhisperKit" : "例如：machine learning",
                               text: $draft.source, focus: $sourceFocused, onSubmit: {
                            if draft.kind == .glossary { sourceFocused = false; targetFocused = true } else { save() }
                        }, fill: theme.ground)
                        .accessibilityLabel(draft.kind == .hotWord ? "热词内容" : "术语原文")
                }
                if draft.kind == .glossary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("固定译法").font(LLFont.label).foregroundStyle(theme.ink2)
                        QuietField(placeholder: "例如：机器学习", text: $draft.target, focus: $targetFocused, onSubmit: save,
                                   fill: theme.ground)
                            .accessibilityLabel("术语固定译法")
                    }
                }
            }
            if !error.isEmpty { SettingsNote(error, color: theme.brick) }
            HStack(spacing: 16) {
                Spacer()
                Button("取消", action: onCancel).buttonStyle(TextButtonStyle(flush: true))
                    .keyboardShortcut(.escape, modifiers: [])
                Button(draft.original == nil ? "添加" : "保存修改", action: save)
                    .buttonStyle(CompactCapsuleButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (draft.kind == .glossary && draft.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 500, alignment: .leading).background(theme.surface)
        .task {
            // The field enters an existing settings window; wait for AppKit to attach it
            // before replacing the previous first responder.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            sourceFocused = true
        }
        .onChange(of: draft.source) { _, _ in error = "" }
        .onChange(of: draft.target) { _, _ in error = "" }
        .onChange(of: draft.kind) { _, _ in error = "" }
    }

    private func save() {
        var next = library
        do {
            try next.save(kind: draft.kind, source: draft.source, target: draft.target, replacing: draft.original)
            onSave(next)
        } catch { self.error = error.localizedDescription }
    }
}

struct VocabularyList: View {
    let items: [VocabularyItem]
    let onEdit: (VocabularyItem) -> Void
    let onDelete: (VocabularyItem) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender

    /// No column header: every row names its kind, glossary rows show source over target, and
    /// the count is on the filter above.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if staticRender {
                VStack(spacing: 0) { rows }
            } else {
                LazyVStack(spacing: 0) { rows }
            }
        }
        .padding(.vertical, 4)
        .llCard()
        .clipShape(RoundedRectangle(cornerRadius: LLMetrics.Radius.card, style: .continuous))
    }

    private var rows: some View {
        ForEach(items) { item in
            VocabularyListRow(item: item, onEdit: { onEdit(item) }, onDelete: { onDelete(item) })
            if item.id != items.last?.id { Hairline().padding(.horizontal, 16) }
        }
    }
}

/// One word. The row itself is not a button (编辑 / 移除 are), so it has no hover of its own; the
/// kind label sits on the first line's baseline even when the word wraps.
private struct VocabularyListRow: View {
    let item: VocabularyItem
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.kind.label).font(LLFont.label).foregroundStyle(theme.ink3)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.source).font(LLFont.bodyStrong).foregroundStyle(theme.ink)
                    .lineLimit(2).textSelection(.enabled)
                if item.kind == .glossary {
                    Text(item.isValid ? item.target : "译法缺失，请编辑修复")
                        .font(LLFont.body).foregroundStyle(item.isValid ? theme.ink2 : theme.brick)
                        .lineLimit(2).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.kind == .hotWord ? item.raw : "\(item.source) → \(item.target)")
            Button("编辑", action: onEdit).buttonStyle(TextButtonStyle())
                .accessibilityLabel("编辑\(item.source)")
            Button("移除", action: onDelete).buttonStyle(TextButtonStyle(tint: theme.ink3, flush: true))
                .accessibilityLabel("移除\(item.source)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contextMenu {
            Button("编辑", action: onEdit)
            Button("移除", role: .destructive, action: onDelete)
        }
    }
}
