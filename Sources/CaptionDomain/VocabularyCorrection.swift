import Foundation

/// A local hypothesis, never an instruction to a recognizer or translator. Offsets count
/// extended grapheme clusters, so a mixed Chinese / emoji sentence can be edited safely.
public struct VocabularyCorrectionCandidate: Sendable, Codable, Equatable, Identifiable {
    public enum Reason: String, Sendable, Codable {
        case similarSpelling, samePronunciation
        public var label: String { self == .samePronunciation ? "普通话近音" : "相近拼写" }
    }
    public var start: Int
    public var length: Int
    public let original: String
    public let replacement: String
    public let reason: Reason
    public var id: String { "\(start):\(length):\(original):\(replacement)" }

    public init(start: Int, length: Int, original: String, replacement: String, reason: Reason) {
        self.start = start; self.length = length; self.original = original
        self.replacement = replacement; self.reason = reason
    }

    /// Called only by an explicit confirmation. The owner must also check session,
    /// segment, source revision and membership in the currently displayed candidates.
    public func applying(to text: String) -> String? {
        guard start >= 0, length > 0, start <= text.count, length <= text.count - start,
              !replacement.isEmpty, replacement != original else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: length)
        guard String(text[lower..<upper]) == original else { return nil }
        return String(text[..<lower]) + replacement + String(text[upper...])
    }
}

extension CaptionSegment {
    /// Revision-bound, per-occurrence confirmation. It never learns a global alias.
    @discardableResult
    public mutating func confirmVocabularyCorrection(_ candidate: VocabularyCorrectionCandidate, revision: Int) -> Bool {
        guard sourceFinal, sourceRevision == revision,
              vocabularyCandidates?.contains(candidate) == true,
              let text = candidate.applying(to: sourceText) else { return false }
        if originalRecognitionText == nil { originalRecognitionText = sourceText }
        history.append(sourceText)
        if history.count > 8 { history.removeFirst(history.count - 8) }
        sourceText = text
        sourceRevision += 1
        corrected = true
        if translation != nil { translation?.isStale = true }
        let end = candidate.start + candidate.length
        vocabularyCandidates = vocabularyCandidates?.compactMap { other in
            guard other.start + other.length <= candidate.start || other.start >= end else { return nil }
            var next = other
            if next.start >= end { next.start += candidate.replacement.count - candidate.length }
            return next.applying(to: text) == nil ? nil : next
        }
        // A confirmed edit does not secretly call a paid translation backend. Existing
        // translations remain visibly stale until explicitly regenerated elsewhere.
        if presentationState != .frozen { presentationState = .stable }
        return true
    }

    @discardableResult
    public mutating func dismissVocabularyCorrection(_ candidate: VocabularyCorrectionCandidate, revision: Int) -> Bool {
        guard sourceRevision == revision, vocabularyCandidates?.contains(candidate) == true else { return false }
        vocabularyCandidates?.removeAll { $0.start == candidate.start && $0.length == candidate.length }
        return true
    }
}

extension CaptionSnapshot {
    @discardableResult
    public mutating func reviewVocabularyCandidate(segmentID: String, revision: Int,
                                                   candidate: VocabularyCorrectionCandidate, confirm: Bool) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == segmentID }), case .segment(var segment) = items[index] else { return false }
        let changed = confirm ? segment.confirmVocabularyCorrection(candidate, revision: revision)
                              : segment.dismissVocabularyCorrection(candidate, revision: revision)
        guard changed else { return false }
        items[index] = .segment(segment)
        if confirm {
            for i in items.indices where i != index {
                guard case .segment(var owner) = items[i], owner.translation?.coveredSegmentIDs.contains(segmentID) == true else { continue }
                owner.translation?.isStale = true
                if owner.presentationState != .frozen { owner.presentationState = .stable }
                items[i] = .segment(owner)
            }
        }
        version &+= 1
        return true
    }
}
