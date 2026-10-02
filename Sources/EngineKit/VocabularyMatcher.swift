import Foundation

/// Shared vocabulary spelling and phrase matching, independent of any engine vendor.
/// Exact letters are required; only ASCII case and separators may differ. No fuzzy or
/// phonetic replacement that could turn unrelated speech into a preferred term.
public struct VocabularyTerm: Sendable, Equatable {
    public var source: String
    public var target: String
    public init(source: String, target: String) { self.source = source; self.target = target }
}

public struct VocabularyMatcher: Sendable {
    public struct Match: Sendable {
        public let range: Range<String.Index>
        public let replacement: String
    }
    private struct Entry: Sendable {
        let core: String
        let target: String
        let shortASCII: Bool
    }
    private struct Node: Sendable {
        var children: [Character: Int] = [:]
        var entries: [Entry] = []
    }
    private var nodes = [Node()]

    public init(_ terms: [VocabularyTerm]) {
        for term in terms {
            let core = term.source.filter { !Self.separator($0) }
            guard !core.isEmpty, !term.target.isEmpty else { continue }
            var node = 0
            for char in core {
                let key = Self.fold(char)
                if let next = nodes[node].children[key] { node = next }
                else {
                    let next = nodes.count
                    nodes.append(Node())
                    nodes[node].children[key] = next
                    node = next
                }
            }
            if !nodes[node].entries.contains(where: { $0.core == core }) {
                nodes[node].entries.append(Entry(core: core, target: term.target,
                                                  shortASCII: core.count < 4 && core.allSatisfy(Self.asciiWord)))
            }
        }
    }

    public func matches(in text: String) -> [Match] {
        guard nodes.count > 1 else { return [] }
        let characters = Array(text)
        let indices = Array(text.indices) + [text.endIndex]
        var result: [Match] = []
        var start = 0
        while start < characters.count {
            if Self.separator(characters[start]) || (start > 0 && Self.asciiWord(characters[start]) && Self.asciiWord(characters[start - 1])) {
                start += 1; continue
            }
            var node = 0, end = start
            var core = ""
            var best: (end: Int, target: String)?
            while end < characters.count {
                let char = characters[end]
                if Self.separator(char) { end += 1; continue }
                guard let next = nodes[node].children[Self.fold(char)] else { break }
                node = next; core.append(char); end += 1
                let boundary = end == characters.count || !Self.asciiWord(char) || !Self.asciiWord(characters[end])
                guard boundary, !nodes[node].entries.isEmpty else { continue }
                let entries = nodes[node].entries
                if let exact = entries.first(where: { $0.core == core }) {
                    best = (end, exact.target)
                } else if entries.count == 1, let entry = entries.first {
                    let raw = characters[start..<end]
                    let spelledOut = raw.split(whereSeparator: Self.separator).count == core.count && core.count > 1
                    if !entry.shortASCII || spelledOut { best = (end, entry.target) }
                }
            }
            if let best {
                result.append(Match(range: indices[start]..<indices[best.end], replacement: best.target))
                start = best.end
            } else { start += 1 }
        }
        return result
    }

    public func replacing(in text: String) -> String {
        let matches = matches(in: text)
        guard !matches.isEmpty else { return text }
        var result = "", cursor = text.startIndex
        for match in matches {
            result += text[cursor..<match.range.lowerBound]
            result += match.replacement
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    public static func uniqueWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func separator(_ c: Character) -> Bool { c == " " || c == "\t" || c == "-" }
    private static func fold(_ c: Character) -> Character {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first, (65...90).contains(scalar.value) else { return c }
        return Character(UnicodeScalar(scalar.value + 32)!)
    }
    private static func asciiWord(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else { return false }
        return (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || c == "_"
    }
}
