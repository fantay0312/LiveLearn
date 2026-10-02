import Foundation

/// Keeps the volatile tail replaceable until the recognizer closes its time range.
public struct DictationDocument: Sendable {
    private var finalized: [TranscriptChunk] = []
    private var pending: TranscriptChunk?
    private var watermark: Int64 = -1

    public init() {}

    public mutating func receive(_ chunk: TranscriptChunk) {
        guard chunk.endNs >= chunk.startNs, chunk.endNs > watermark else { return }
        if chunk.isFinal {
            finalized.append(chunk)
            watermark = chunk.endNs
            if let tail = pending, tail.endNs <= watermark || tail.startNs < watermark { pending = nil }
        } else {
            guard chunk.startNs >= max(0, watermark) else { return }
            pending = chunk
        }
    }

    public var text: String {
        (finalized.map(\.text) + [pending?.text].compactMap { $0 })
            .reduce("") { Self.join($0, $1) }
    }

    public static func join(_ left: String, _ right: String) -> String {
        guard let a = left.last, let b = right.first else { return left + right }
        let needsSpace = !a.isWhitespace && !b.isWhitespace &&
            a.unicodeScalars.allSatisfy { $0.isASCII } &&
            b.unicodeScalars.allSatisfy { $0.isASCII } && b.isLetter && (a.isLetter || a.isNumber || ".!?".contains(a))
        return left + (needsSpace ? " " : "") + right
    }
}

/// An edit owns exactly the original selection. UTF-16 matches macOS accessibility ranges.
public struct DictationInsertion: Sendable, Equatable {
    public let original: String
    public let range: NSRange
    public private(set) var inserted: String?

    public init?(text: String, selection: NSRange) {
        let utf16 = text.utf16
        guard selection.location >= 0, selection.length >= 0, selection.location <= utf16.count,
              selection.length <= utf16.count - selection.location else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: selection.location)
        let end = utf16.index(start, offsetBy: selection.length)
        guard start.samePosition(in: text.unicodeScalars) != nil,
              end.samePosition(in: text.unicodeScalars) != nil else { return nil }
        original = text
        range = selection
    }

    public var expectedText: String {
        guard let inserted else { return original }
        return (original as NSString).replacingCharacters(in: range, with: inserted)
    }

    public var expectedSelection: NSRange {
        guard let inserted else { return range }
        return NSRange(location: range.location + inserted.utf16.count, length: 0)
    }

    public var replacementRange: NSRange {
        NSRange(location: range.location, length: inserted?.utf16.count ?? range.length)
    }

    public func accepts(text: String, selection: NSRange) -> Bool {
        text == expectedText && selection == expectedSelection
    }

    public mutating func replace(with text: String) { inserted = text }
}
