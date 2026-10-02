import Foundation

/// Decides what a finalized translation adds to what has already been spoken, so the reader
/// who listens instead of reads hears each sentence once. Pure value logic.
///
/// - A sentence that is the same as one spoken recently (case, width and punctuation folded)
///   is skipped: a revision that changed only punctuation is not read twice.
/// - A sentence that extends the last spoken one (the final of a sentence whose earlier
///   revision was already read) contributes only its new tail.
/// - Everything else is spoken whole.
public struct ReadAloudGate: Sendable, Equatable {
    public var memory = 40
    private var spoken: [String] = []
    private var lastRaw: String?

    public init() {}

    /// The text to speak for this translation, or nil when nothing new is in it.
    public mutating func speakable(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let key = Self.fold(raw)
        guard !key.isEmpty, !spoken.contains(key) else { return nil }
        var out = raw
        if let last = lastRaw, raw.count > last.count, raw.hasPrefix(last) {
            // Drop the joint's leading punctuation and spaces; keep the sentence's own ending.
            var tail = Substring(raw.dropFirst(last.count))
            while let f = tail.first, f.isWhitespace || f.isPunctuation { tail = tail.dropFirst() }
            let text = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.fold(text).count >= 2 { out = text } else { return nil }
        }
        remember(key)
        lastRaw = raw
        return out
    }

    public mutating func reset() {
        spoken = []
        lastRaw = nil
    }

    private mutating func remember(_ key: String) {
        spoken.append(key)
        if spoken.count > memory { spoken.removeFirst(spoken.count - memory) }
    }

    /// Lowercased, diacritics and punctuation removed, all whitespace collapsed.
    static func fold(_ s: String) -> String {
        let base = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(base.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
