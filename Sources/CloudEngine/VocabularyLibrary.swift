import Foundation

/// A value snapshot of the two existing preference arrays. Editing and import are transactional:
/// validation never destroys the original entry, and import never overwrites an existing mapping.
public struct VocabularyLibrary: Equatable, Sendable, Codable {
    public var hotWords: [String]
    public var glossaryLines: [String]
    public static let glossaryLimit = 200
    public static let importByteLimit = 262_144

    public init(hotWords: [String] = [], glossaryLines: [String] = []) {
        self.hotWords = hotWords
        self.glossaryLines = glossaryLines
    }

    public var items: [VocabularyItem] {
        var seen = Set<String>()
        return (hotWords.map { VocabularyItem(kind: .hotWord, raw: $0) }
            + glossaryLines.map { VocabularyItem(kind: .glossary, raw: $0) })
            .filter { seen.insert($0.id).inserted }
    }

    /// Whitespace and canonical Unicode differences are duplicates; letter case remains
    /// meaningful for identifiers such as US/us and technical terms such as R/r.
    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    @discardableResult
    public mutating func save(kind: VocabularyKind, source: String, target: String = "",
                              replacing original: VocabularyItem? = nil) throws -> VocabularyItem {
        let source = Self.key(source), target = Self.key(target)
        guard !source.isEmpty else { throw VocabularyError.invalid("请填写\(kind == .hotWord ? "热词" : "原文")。") }
        guard !source.contains(where: \.isNewline), !target.contains(where: \.isNewline) else {
            throw VocabularyError.invalid("每个词条只能有一行；多条内容请使用批量导入。")
        }
        guard source.count <= 240, target.count <= 240 else {
            throw VocabularyError.invalid("原文和译文分别最多 240 个字符，请精简后再保存。")
        }
        var next = self
        if let original { next.remove(original) }
        let item: VocabularyItem
        switch kind {
        case .hotWord:
            guard !next.hotWords.contains(where: { Self.key($0) == source }) else { throw VocabularyError.duplicate }
            item = VocabularyItem(kind: kind, raw: source)
        case .glossary:
            guard !target.isEmpty else { throw VocabularyError.invalid("请填写固定译法。") }
            let line = "\(source)=\(target)"
            guard GlossaryEntry.parse([line]).first == GlossaryEntry(source: source, target: target) else {
                throw VocabularyError.invalid("原文中不能包含等号或箭头等分隔符。")
            }
            for entry in GlossaryEntry.parse(next.glossaryLines) where Self.key(entry.source) == source {
                if Self.key(entry.target) == target { throw VocabularyError.duplicate }
                throw VocabularyError.invalid("「\(source)」已有译法「\(entry.target)」，请编辑原词条。")
            }
            guard GlossaryEntry.parse(next.glossaryLines).count < Self.glossaryLimit else {
                throw VocabularyError.invalid("术语已达到 200 条，请整理后再添加；翻译引擎最多使用 200 条。")
            }
            item = VocabularyItem(kind: kind, raw: line)
        }
        // Editing retains the stored order because it also determines prompt priority.
        switch kind {
        case .hotWord:
            let index = original.flatMap { hotWords.firstIndex(of: $0.raw) } ?? next.hotWords.endIndex
            next.hotWords.insert(item.raw, at: min(index, next.hotWords.endIndex))
        case .glossary:
            let index = original.flatMap { glossaryLines.firstIndex(of: $0.raw) } ?? next.glossaryLines.endIndex
            next.glossaryLines.insert(item.raw, at: min(index, next.glossaryLines.endIndex))
        }
        self = next
        return item
    }

    public mutating func remove(_ item: VocabularyItem) {
        switch item.kind {
        case .hotWord: hotWords.removeAll { $0 == item.raw }
        case .glossary: glossaryLines.removeAll { $0 == item.raw }
        }
    }

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// TXT/TSV paste or a lossless JSON backup. A report is a preview until the caller commits.
    public func previewImport(_ text: String) -> VocabularyImportReport {
        var report = VocabularyImportReport(library: self)
        guard text.utf8.count <= Self.importByteLimit else {
            report.issues = ["内容超过 256 KB，请拆分后导入。"]
            return report
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        let candidates: [(Int, VocabularyKind, String, String)]
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            guard let backup = try? JSONDecoder().decode(Self.self, from: Data(trimmed.utf8)) else {
                report.issues = ["备份格式无法识别，请选择 LiveLearn 导出的 JSON 文件。"]
                return report
            }
            candidates = backup.items.enumerated().map { offset, item in
                (offset + 1, item.kind, item.source, item.target)
            }
        } else {
            candidates = trimmed.components(separatedBy: .newlines).enumerated().compactMap { offset, raw in
                let line = Self.key(raw)
                guard !line.isEmpty else { return nil }
                if let entry = GlossaryEntry.parse([line]).first {
                    return (offset + 1, .glossary, entry.source, entry.target)
                }
                if ["=", "＝", "→", "->", "\t", "：", ":"].contains(where: raw.contains) {
                    return (offset + 1, .glossary, line, "")
                }
                return (offset + 1, .hotWord, line, "")
            }
        }
        guard candidates.count <= 2_000 else {
            report.issues = ["一次最多导入 2,000 条，请拆分后重试。"]
            return report
        }
        for (line, kind, source, target) in candidates {
            do {
                let item = try report.library.save(kind: kind, source: source, target: target)
                report.added.append(item)
            } catch VocabularyError.duplicate {
                report.duplicates += 1
            } catch {
                report.issues.append("第 \(line) 条：\(error.localizedDescription)")
            }
        }
        return report
    }
}

public enum VocabularyKind: String, CaseIterable, Sendable, Identifiable {
    case hotWord, glossary
    public var id: String { rawValue }
    public var label: String { self == .hotWord ? "热词" : "术语" }
}

public struct VocabularyItem: Identifiable, Equatable, Sendable {
    public let kind: VocabularyKind
    public let raw: String
    public var id: String { kind.rawValue + ":" + raw }
    public var entry: GlossaryEntry? { kind == .glossary ? GlossaryEntry.parse([raw]).first : nil }
    public var source: String { entry?.source ?? raw }
    public var target: String { entry?.target ?? "" }
    public var isValid: Bool { kind == .hotWord ? !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : entry != nil }

    public init(kind: VocabularyKind, raw: String) { self.kind = kind; self.raw = raw }

    public func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            source.localizedStandardContains($0) || target.localizedStandardContains($0)
        }
    }
}

public struct VocabularyImportReport: Equatable, Sendable {
    public var library: VocabularyLibrary
    public var added: [VocabularyItem] = []
    public var duplicates = 0
    public var issues: [String] = []
}

public enum VocabularyError: Error, LocalizedError {
    case duplicate
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate: return "这个词条已经存在。"
        case .invalid(let message): return message
        }
    }
}
