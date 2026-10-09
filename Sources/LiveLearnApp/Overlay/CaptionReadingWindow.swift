import Foundation
import NaturalLanguage
import CaptionDomain

struct CaptionReadingLine: Equatable, Identifiable {
    let id: String
    var source: String
    let translation: String?
    let isFinal: Bool

    func primaryText(showSource: Bool) -> String? {
        if let translation, !translation.isEmpty { return translation }
        return showSource && !source.isEmpty ? source : nil
    }
}

/// A bounded reading surface. The transcript and archived segments remain untouched.
///
/// `current` is the sentence being spoken, from the moment it has a translation: it grows in
/// the prominent slot and the sentence before it moves up to `previous`. Only the first words
/// of a sentence nothing has been translated for yet wait in `incoming`, under the last
/// translated line, so a translation is never replaced by text the reader cannot read.
struct CaptionReadingWindow: Equatable {
    var previous: CaptionReadingLine?
    var current: CaptionReadingLine?
    var incoming: CaptionReadingLine?

    /// Reading width (CJK glyph = 1, Latin ≈ 0.55) an untranslated opening needs before it is
    /// shown under the settled line. A local translator answers within the first few words, so
    /// below this the opening would only flash there on its way to the prominent slot.
    static let incomingMinimum = 8.0

    init(current: CaptionSegment?, previous: CaptionSegment?, earlier: CaptionSegment? = nil, capacity: Double = 28) {
        guard let current else { return }
        let latest = Self.lines(current, capacity: capacity)
        let prior = previous.map { Self.lines($0, capacity: capacity) } ?? []
        if let live = latest.last, live.translation != nil {
            self.current = live
            self.previous = latest.dropLast().last ?? prior.last
        } else if let settled = prior.last, settled.translation != nil {
            self.current = settled
            self.previous = prior.dropLast().last ?? earlier.flatMap { Self.lines($0, capacity: capacity).last }
            if let opening = latest.last, Self.width(opening.source) >= Self.incomingMinimum { incoming = opening }
        } else {
            self.current = latest.last
            self.previous = latest.dropLast().last ?? prior.last
        }
    }

    private static func lines(_ segment: CaptionSegment, capacity: Double) -> [CaptionReadingLine] {
        let source = sentences(segment.sourceText)
        let translated = segment.translation.map { sentences($0.text) } ?? []
        let final = segment.presentationState == .final || segment.presentationState == .frozen
        // Still being spoken or translated: its last line is still filling.
        let open = segment.presentationState == .preview || segment.presentationState == .listening
            || segment.presentationState == .awaitingTranslation
        var result: [CaptionReadingLine]
        // Translation may combine or reorder sentences. Only split a bilingual segment when its
        // source and translation expose the same sentence boundaries by count. A translation a
        // revision behind its source pairs the same way: a live sentence is in that state between
        // every two partial translations, and its source row must not change with it.
        if source.count == translated.count, !source.isEmpty {
            result = source.indices.flatMap { index in
                let pieces = readingUnits(translated[index], capacity: capacity, openEnded: open && index == source.count - 1)
                let sameText = source[index] == translated[index]
                return pieces.indices.map { piece in
                    CaptionReadingLine(id: "\(segment.id)/\(index)/\(piece)",
                                       source: sameText ? pieces[piece] : piece == pieces.count - 1 ? source[index] : "",
                                       translation: pieces[piece], isFinal: final)
                }
            }
        } else if segment.translation == nil {
            result = readingUnits(segment.sourceText, capacity: capacity, openEnded: open).enumerated().map { index, text in
                CaptionReadingLine(id: "\(segment.id)/\(index)", source: text, translation: nil, isFinal: final)
            }
        } else {
            let pieces = readingUnits(segment.translation?.text ?? "", capacity: capacity, openEnded: open)
            result = pieces.indices.map { index in
                CaptionReadingLine(id: "\(segment.id)/\(index)", source: index == pieces.count - 1 ? segment.sourceText : "",
                                   translation: pieces[index], isFinal: final)
            }
        }
        // A line that has only just begun holds a word or two. While the sentence is open the
        // full line before it stays in place until the new one has something to read.
        if open, result.count > 1, let tail = result.last,
           width(tail.translation ?? tail.source) < minimumTail(capacity) {
            result.removeLast()
            if result[result.count - 1].source.isEmpty { result[result.count - 1].source = tail.source }
        }
        return result
    }

    private static func width(_ text: String) -> Double {
        text.reduce(0.0) { $0 + ($1.isASCII ? 0.55 : 1) }
    }

    /// The least a line may hold before it stands on its own.
    private static func minimumTail(_ capacity: Double) -> Double { min(6, max(8, capacity) / 4) }

    private static let clauseBreaks = "，、,;；:："

    /// Reading cues do not depend on the recognizer inserting punctuation. Split at a nearby
    /// word/clause boundary, then fall back to a grapheme boundary for long CJK runs. A finished
    /// sentence never ends on a stub: its last two cues are split evenly instead. `openEnded`
    /// leaves the last sentence's tail alone, because it is still growing.
    static func readingUnits(_ text: String, capacity: Double = 28, openEnded: Bool = false) -> [String] {
        let budget = max(8, capacity)
        var result: [String] = []
        let all = sentences(text)
        for (position, sentence) in all.enumerated() {
            // Untrimmed, so two neighbours join back into the text they were cut from.
            var pieces: [String] = []
            var buffer = "", used = 0.0
            for character in sentence {
                let width = character.isASCII ? 0.55 : 1.0
                if used + width > budget, !buffer.isEmpty {
                    let boundaries = buffer.indices.filter { buffer[$0].isWhitespace || clauseBreaks.contains(buffer[$0]) }
                    if let cut = boundaries.last, buffer.distance(from: cut, to: buffer.endIndex) < 14 {
                        let end = buffer.index(after: cut)
                        pieces.append(String(buffer[..<end]))
                        buffer = String(buffer[end...])
                    } else {
                        pieces.append(buffer)
                        buffer = ""
                    }
                    used = Self.width(buffer)
                }
                buffer.append(character)
                used += width
            }
            if !buffer.isEmpty { pieces.append(buffer) }
            if pieces.count > 1, !(openEnded && position == all.count - 1),
               Self.width(pieces[pieces.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)) < minimumTail(budget) {
                pieces.replaceSubrange((pieces.count - 2)..., with: halves(pieces[pieces.count - 2] + pieces[pieces.count - 1]))
            }
            result += pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result.filter { !$0.isEmpty }
    }

    /// Two cues of about the same reading width, cut at the word or clause boundary nearest the
    /// middle, or at the middle grapheme when the text has none there.
    private static func halves(_ text: String) -> [String] {
        let total = width(text)
        var used = 0.0
        var middle = text.endIndex
        var boundary: (index: String.Index, distance: Double)?
        for index in text.indices {
            used += text[index].isASCII ? 0.55 : 1
            let distance = abs(used - total / 2)
            if middle == text.endIndex, used >= total / 2 { middle = text.index(after: index) }
            if text[index].isWhitespace || clauseBreaks.contains(text[index]),
               distance <= total * 0.2, distance < boundary?.distance ?? .infinity {
                boundary = (text.index(after: index), distance)
            }
        }
        let cut = boundary?.index ?? middle
        return [String(text[..<cut]), String(text[cut...])]
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
