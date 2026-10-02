import Foundation
import NaturalLanguage
import CaptionDomain

struct CaptionReadingLine: Equatable, Identifiable {
    let id: String
    let source: String
    let translation: String?
    let isStale: Bool
    let isFinal: Bool

    func primaryText(showSource: Bool) -> String? {
        if let translation, !translation.isEmpty { return translation }
        return showSource && !source.isEmpty ? source : nil
    }
}

/// A bounded reading surface. The transcript and archived segments remain untouched.
struct CaptionReadingWindow: Equatable {
    var previous: CaptionReadingLine?
    var current: CaptionReadingLine?
    var incoming: CaptionReadingLine?

    init(current: CaptionSegment?, previous: CaptionSegment?, earlier: CaptionSegment? = nil, capacity: Double = 28) {
        guard let current else { return }
        let latest = Self.lines(current, capacity: capacity)
        let prior = previous.map { Self.lines($0, capacity: capacity) } ?? []
        let pending = current.presentationState == .preview || current.presentationState == .awaitingTranslation || current.presentationState == .listening
        if pending, latest.count > 1 {
            self.current = latest.dropLast().last
            self.previous = latest.dropLast(2).last ?? prior.last
            incoming = latest.last
        } else if pending, let settled = prior.last, settled.translation != nil {
            self.current = settled
            self.previous = prior.dropLast().last ?? earlier.flatMap { Self.lines($0, capacity: capacity).last }
            incoming = latest.last
        } else {
            self.current = latest.last
            self.previous = latest.dropLast().last ?? prior.last
        }
    }

    private static func lines(_ segment: CaptionSegment, capacity: Double) -> [CaptionReadingLine] {
        let source = sentences(segment.sourceText)
        let translated = segment.translation.map { sentences($0.text) } ?? []
        let final = segment.presentationState == .final || segment.presentationState == .frozen
        let stale = segment.translation?.isStale ?? false
        // Translation may combine or reorder sentences. Only split a bilingual segment when
        // its current source and translation expose the same sentence boundaries by count.
        if !stale, source.count == translated.count, !source.isEmpty {
            return source.indices.flatMap { index in
                let pieces = readingUnits(translated[index], capacity: capacity)
                let sameText = source[index] == translated[index]
                return pieces.indices.map { piece in
                    CaptionReadingLine(id: "\(segment.id)/\(index)/\(piece)",
                                       source: sameText ? pieces[piece] : piece == pieces.count - 1 ? source[index] : "",
                                       translation: pieces[piece], isStale: false, isFinal: final)
                }
            }
        }
        if segment.translation == nil {
            return readingUnits(segment.sourceText, capacity: capacity).enumerated().map { index, text in
                CaptionReadingLine(id: "\(segment.id)/\(index)", source: text, translation: nil, isStale: false, isFinal: final)
            }
        }
        let pieces = readingUnits(segment.translation?.text ?? "", capacity: capacity)
        return pieces.indices.map { index in
            CaptionReadingLine(id: "\(segment.id)/\(index)", source: index == pieces.count - 1 ? segment.sourceText : "",
                               translation: pieces[index], isStale: stale, isFinal: final)
        }
    }

    /// Reading cues do not depend on the recognizer inserting punctuation. Split at a nearby
    /// word/clause boundary, then fall back to a grapheme boundary for long CJK runs.
    static func readingUnits(_ text: String, capacity: Double = 28) -> [String] {
        let budget = max(8, capacity)
        var result: [String] = []
        for sentence in sentences(text) {
            var buffer = "", used = 0.0
            for character in sentence {
                let width = character.isASCII ? 0.55 : 1.0
                if used + width > budget, !buffer.isEmpty {
                    let boundaries = buffer.indices.filter { buffer[$0].isWhitespace || "，、,;；:：".contains(buffer[$0]) }
                    if let cut = boundaries.last, buffer.distance(from: cut, to: buffer.endIndex) < 14 {
                        let end = buffer.index(after: cut)
                        result.append(String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
                        buffer = String(buffer[end...])
                    } else {
                        result.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                        buffer = ""
                    }
                    used = buffer.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1) }
                }
                buffer.append(character)
                used += width
            }
            if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return result.filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// CJK glyphs use one em, Latin about half. Keep the newest words for long unpunctuated
    /// input rather than letting lineLimit hide every new word at the end of a paragraph.
    static func excerpt(_ text: String, capacity: Double) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = max(4, capacity)
        var used = 0.0
        var suffix: [Character] = []
        for character in trimmed.reversed() {
            let width = character.isASCII ? 0.55 : 1.0
            if used + width > budget - 1 { break }
            suffix.append(character)
            used += width
        }
        guard suffix.count < trimmed.count else { return trimmed }
        var result = String(suffix.reversed())
        if result.first?.isASCII == true, let space = result.firstIndex(where: \.isWhitespace), result.distance(from: result.startIndex, to: space) < 16 {
            result = String(result[result.index(after: space)...])
        }
        return "…" + result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
