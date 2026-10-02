import Foundation

/// Applies a reading-stability policy to caption snapshots before they reach any view.
///
/// The reducer's snapshot is the truth; the presenter only decides *when* a newer partial of
/// the current sentence replaces the one on screen. A preview line is held for at least
/// `dwellNs` before a newer preview of the same segment may replace it. Finals, corrections,
/// translations, gaps, frozen states and new sentences are never delayed, so the final text is
/// identical for every dwell value; only the number of intermediate repaints differs.
///
/// Pure value type: the app feeds it snapshots and a clock, and re-runs it at `nextCheckNs`.
public struct CaptionPresenter: Sendable {
    public var dwellNs: Int64
    private var held: [String: Held] = [:]
    private var sessionID: String?

    private struct Held: Sendable {
        var segment: CaptionSegment
        var shownAtNs: Int64
    }

    public init(dwellNs: Int64) {
        self.dwellNs = max(0, dwellNs)
    }

    public struct Result: Sendable {
        public var snapshot: CaptionSnapshot
        /// Time at which a held preview becomes eligible for replacement; nil when nothing waits.
        public var nextCheckNs: Int64?
    }

    public mutating func present(_ source: CaptionSnapshot, nowNs: Int64) -> Result {
        if sessionID != source.sessionID {
            sessionID = source.sessionID
            held = [:]
        }
        guard dwellNs > 0 else {
            held = [:]
            return Result(snapshot: source, nextCheckNs: nil)
        }
        var out = source
        var nextCheck: Int64? = nil
        // Latest segment per lane is the only candidate for holding.
        var latestIndex: [String: Int] = [:]
        for (i, item) in source.items.enumerated() {
            if case .segment(let s) = item { latestIndex[s.laneID] = i }
        }
        for (lane, i) in latestIndex {
            guard case .segment(let current) = source.items[i] else { continue }
            guard let h = held[lane], h.segment.id == current.id else {
                held[lane] = Held(segment: current, shownAtNs: nowNs)   // new sentence: show now
                continue
            }
            if h.segment == current { continue }
            if Self.mustShowImmediately(previous: h.segment, current: current) {
                held[lane] = Held(segment: current, shownAtNs: nowNs)
                continue
            }
            let eligibleAt = h.shownAtNs + dwellNs
            if nowNs >= eligibleAt {
                held[lane] = Held(segment: current, shownAtNs: nowNs)
            } else {
                out.items[i] = .segment(h.segment)
                nextCheck = min(nextCheck ?? eligibleAt, eligibleAt)
            }
        }
        // Forget lanes that no longer have a segment.
        held = held.filter { latestIndex[$0.key] != nil }
        return Result(snapshot: out, nextCheckNs: nextCheck)
    }

    /// Anything other than "a newer partial of the same open sentence" is shown at once.
    private static func mustShowImmediately(previous: CaptionSegment, current: CaptionSegment) -> Bool {
        if current.presentationState != .preview { return true }
        if current.sourceFinal || current.corrected { return true }
        if current.translation != previous.translation { return true }
        if current.mergedIntoTranslation != previous.mergedIntoTranslation { return true }
        return false
    }
}
