import Foundation
import CaptionDomain

/// Vendor-independent, offline retrieval. These are hypotheses, not confidence scores.
/// Exact word boundaries, bounded spans and a vocabulary index keep it off the audio path.
/// No model prompt, learned aliases, or substitutions are produced here.
public struct VocabularyCandidateGenerator: Sendable {
    private struct Entry: Sendable {
        let word: String
        let key: [Character]
    }
    private var latin: [Character: [Int: [Entry]]] = [:]
    private var mandarin: [Int: [String: [String]]] = [:]
    private let exact: VocabularyMatcher
    public static let candidateLimit = 12

    public init(vocabulary: [String]) {
        let words = VocabularyMatcher.uniqueWords(vocabulary)
        exact = VocabularyMatcher(words.map { VocabularyTerm(source: $0, target: $0) })
        for word in words {
            let key = Array(Self.latinKey(word))
            if (5...48).contains(key.count), word.allSatisfy({ Self.asciiLetter($0) || Self.separator($0) }),
               let first = key.first {
                latin[first, default: [:]][key.count, default: []].append(Entry(word: word, key: key))
            } else if (2...8).contains(word.count), word.allSatisfy(Self.han) {
                mandarin[word.count, default: [:]][Self.pronunciation(word), default: []].append(word)
            }
        }
    }

    public func candidates(in text: String) -> [VocabularyCorrectionCandidate] {
        guard !text.isEmpty, text.count <= 4096, !latin.isEmpty || !mandarin.isEmpty else { return [] }
        let chars = Array(text)
        let indices = Array(text.indices) + [text.endIndex]
        let protected = exact.matches(in: text).map(\.range)
        var found: [(VocabularyCorrectionCandidate, Int)] = []
        func add(start: Int, end: Int, word: String, reason: VocabularyCorrectionCandidate.Reason, distance: Int) {
            let range = indices[start]..<indices[end]
            guard !protected.contains(where: { $0.overlaps(range) }) else { return }
            let original = String(chars[start..<end])
            guard original != word else { return }
            found.append((VocabularyCorrectionCandidate(start: start, length: end - start, original: original,
                                                         replacement: word, reason: reason), distance))
        }
        for start in chars.indices {
            if Self.asciiLetter(chars[start]), start == 0 || !Self.identifier(chars[start - 1]) {
                guard let bucket = latin[Character(String(chars[start]).lowercased())] else { continue }
                var end = start, words = 0
                while end < chars.count, words < 4 {
                    guard Self.asciiLetter(chars[end]) else { break }
                    while end < chars.count, Self.asciiLetter(chars[end]) { end += 1 }
                    words += 1
                    if end < chars.count, Self.identifier(chars[end]) { break }
                    let key = Array(Self.latinKey(String(chars[start..<end])))
                    if key.count > 48 { break }
                    if key.count >= 5 {
                        for size in max(5, key.count - 3)...min(48, key.count + 3) {
                            for entry in bucket[size] ?? [] {
                                let budget = min(3, max(1, max(size, key.count) / 3))
                                let distance = Self.distance(key, entry.key, limit: budget)
                                guard distance > 0, distance <= budget else { continue }
                                add(start: start, end: end, word: entry.word, reason: .similarSpelling, distance: distance)
                            }
                        }
                    }
                    while end < chars.count, Self.separator(chars[end]) { end += 1 }
                }
            } else if Self.han(chars[start]) {
                for size in mandarin.keys.sorted() where start + size <= chars.count {
                    let span = chars[start..<(start + size)]
                    guard span.allSatisfy(Self.han) else { continue }
                    let original = String(span)
                    for word in mandarin[size]?[Self.pronunciation(original)] ?? [] {
                        add(start: start, end: start + size, word: word, reason: .samePronunciation, distance: 0)
                    }
                }
            }
        }
        // Prefer stronger, longer hypotheses at the same occurrence; deterministic ties.
        found.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.length != $1.0.length { return $0.0.length > $1.0.length }
            if $0.0.start != $1.0.start { return $0.0.start < $1.0.start }
            return $0.0.replacement < $1.0.replacement
        }
        var selected: [VocabularyCorrectionCandidate] = []
        for (candidate, _) in found {
            // Keep alternatives for the same span, but avoid a clutter of nested fragments.
            if selected.contains(where: {
                ($0.start..<$0.start + $0.length).overlaps(candidate.start..<candidate.start + candidate.length)
                    && ($0.start != candidate.start || $0.length != candidate.length)
            }) { continue }
            if !selected.contains(candidate) { selected.append(candidate) }
            if selected.count == Self.candidateLimit { break }
        }
        return selected.sorted { $0.start == $1.start ? $0.replacement < $1.replacement : $0.start < $1.start }
    }

    private static func latinKey(_ text: String) -> String { text.filter { !separator($0) }.lowercased() }
    private static func pronunciation(_ text: String) -> String {
        (text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }
    private static func separator(_ c: Character) -> Bool { c == " " || c == "\t" || c == "-" }
    private static func asciiLetter(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
    }
    private static func identifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    private static func han(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x3134F).contains($0.value) }
    }
    private static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                row[j + 1] = min(row[j] + 1, previous[j + 1] + 1, previous[j] + (left == right ? 0 : 1))
            }
            if row.min()! > limit { return limit + 1 }
            previous = row
        }
        return previous[b.count]
    }
}
