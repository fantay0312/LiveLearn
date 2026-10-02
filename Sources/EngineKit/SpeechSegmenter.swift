import Foundation
import CaptionDomain

/// One recognizer result, already reduced to what the caption model needs. Times are
/// session-relative nanoseconds (the provider anchors the recognizer's clock to the packets it
/// receives). No Speech framework types here so the mapping is testable without macOS 26.
public struct TranscriptChunk: Sendable, Equatable {
    public var startNs: Int64
    public var endNs: Int64
    public var text: String
    public var isFinal: Bool

    public init(startNs: Int64, endNs: Int64, text: String, isFinal: Bool) {
        self.startNs = startNs
        self.endNs = endNs
        self.text = text
        self.isFinal = isFinal
    }
}

/// Maps a stream of volatile / final recognizer results onto caption segments.
///
/// The recognizer reports a growing volatile text for the range since the last finalization,
/// then one final result for (a prefix of) that range; the next volatile result starts where
/// the final ended. The reducer refuses partials for a finalized segment, so every final closes
/// the open segment and the next volatile text opens a new one, never the same id twice.
public struct SpeechSegmenter: Sendable {
    public struct Context: Sendable {
        public var sessionID: String
        public var laneID: String
        public var providerEpoch: UInt64
        public var captureEpoch: UInt64
        public var sourceLanguage: String
        public var targetLanguage: String

        public init(sessionID: String, laneID: String, providerEpoch: UInt64, captureEpoch: UInt64, sourceLanguage: String, targetLanguage: String) {
            self.sessionID = sessionID
            self.laneID = laneID
            self.providerEpoch = providerEpoch
            self.captureEpoch = captureEpoch
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
        }
    }

    /// A source revision the translator should work on.
    public struct TranslationRequest: Sendable, Equatable {
        public var segmentID: String
        public var revision: Int
        public var text: String
        public var isFinal: Bool
    }

    public struct Output: Sendable {
        public var events: [CaptionEvent] = []
        public var translation: TranslationRequest?
    }

    private struct Open {
        var id: String
        var revision: Int
        var startNs: Int64
        var endNs: Int64
        var text: String
    }

    private var open: Open?
    private var segmentCounter = 0
    private var eventCounter = 0
    /// Volatile text shorter than this is shown but not translated (too little context).
    public var minimumPartialLength = 6

    public init() {}

    public var hasOpenSegment: Bool { open != nil }

    /// Forget the open segment (new provider epoch): the reducer freezes it on its own.
    public mutating func reset() {
        open = nil
    }

    public mutating func apply(_ chunk: TranscriptChunk, context: Context) -> Output {
        var out = Output()
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = max(0, chunk.startNs)
        let end = max(start, chunk.endNs)

        if chunk.isFinal {
            if text.isEmpty {
                // The range held no speech. If a volatile guess was showing, close it with the
                // text the user already saw rather than leaving it open forever.
                guard let o = open else { return out }
                let revision = o.revision + 1
                out.events.append(sourceEvent(.sourceFinal, id: o.id, revision: revision, text: o.text, startNs: o.startNs, endNs: max(o.endNs, end), context: context))
                out.translation = TranslationRequest(segmentID: o.id, revision: revision, text: o.text, isFinal: true)
                open = nil
                return out
            }
            let id: String
            let revision: Int
            let segStart: Int64
            if let o = open {
                id = o.id
                revision = o.revision + 1
                segStart = min(o.startNs, start)
            } else {
                id = nextSegmentID()
                revision = 1
                segStart = start
            }
            out.events.append(sourceEvent(.sourceFinal, id: id, revision: revision, text: text, startNs: segStart, endNs: end, context: context))
            out.translation = TranslationRequest(segmentID: id, revision: revision, text: text, isFinal: true)
            open = nil
            return out
        }

        guard !text.isEmpty else { return out }
        if var o = open {
            if o.text == text {
                // Timing-only recognizer updates do not invalidate the in-flight translation
                // or submit identical text again. Preserve the latest end for finalization.
                o.endNs = max(o.endNs, end)
                open = o
                return out
            }
            o.revision += 1
            o.endNs = end
            o.text = text
            open = o
            out.events.append(sourceEvent(.sourceReplace, id: o.id, revision: o.revision, text: text, startNs: o.startNs, endNs: end, context: context))
            if text.count >= minimumPartialLength {
                out.translation = TranslationRequest(segmentID: o.id, revision: o.revision, text: text, isFinal: false)
            }
        } else {
            let o = Open(id: nextSegmentID(), revision: 1, startNs: start, endNs: end, text: text)
            open = o
            out.events.append(sourceEvent(.sourceReplace, id: o.id, revision: 1, text: text, startNs: start, endNs: end, context: context))
            if text.count >= minimumPartialLength {
                out.translation = TranslationRequest(segmentID: o.id, revision: 1, text: text, isFinal: false)
            }
        }
        return out
    }

    /// Event for a translation the translator produced.
    public mutating func translationEvent(for request: TranslationRequest, text: String, context: Context) -> CaptionEvent {
        eventCounter += 1
        var ev = CaptionEvent(type: request.isFinal ? .translationFinal : .translationReplace, sessionID: context.sessionID, laneID: context.laneID, captureEpoch: context.captureEpoch, providerEpoch: context.providerEpoch, eventID: "\(context.laneID)-t\(context.providerEpoch)-\(eventCounter)")
        ev.translationID = "tr-\(request.segmentID)"
        ev.sourceRefs = [SourceRef(segmentID: request.segmentID, revision: request.revision)]
        ev.text = text
        ev.language = context.targetLanguage
        ev.isFinal = request.isFinal
        return ev
    }

    private mutating func nextSegmentID() -> String {
        segmentCounter += 1
        return String(format: "s%04d", segmentCounter)
    }

    private mutating func sourceEvent(_ kind: CaptionEvent.Kind, id: String, revision: Int, text: String, startNs: Int64, endNs: Int64, context: Context) -> CaptionEvent {
        eventCounter += 1
        var ev = CaptionEvent(type: kind, sessionID: context.sessionID, laneID: context.laneID, captureEpoch: context.captureEpoch, providerEpoch: context.providerEpoch, eventID: "\(context.laneID)-e\(context.providerEpoch)-\(eventCounter)")
        ev.segmentID = id
        ev.revision = revision
        ev.text = text
        ev.language = context.sourceLanguage
        ev.isFinal = kind == .sourceFinal
        ev.startNs = startNs
        ev.endNs = endNs
        ev.timingQuality = .segment
        return ev
    }
}
