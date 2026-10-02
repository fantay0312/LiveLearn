import Foundation

/// Application-level caption event. Provider adapters translate vendor messages into this;
/// the reducer never sees vendor objects. Serialized shape is shared with Windows via
/// `contracts/caption-event.schema.json`.
public struct CaptionEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case sourceReplace = "source.replace"
        case sourceFinal = "source.final"
        case sourceCorrection = "source.correction"
        case translationReplace = "translation.replace"
        case translationFinal = "translation.final"
        case laneGap = "lane.gap"
        case laneState = "lane.state"
    }

    public var schemaVersion: Int
    public var type: Kind
    public var sessionID: String
    public var laneID: String
    public var captureEpoch: UInt64
    public var providerEpoch: UInt64
    /// Provider-unique id used for idempotency. Never the text.
    public var eventID: String
    public var segmentID: String?
    public var revision: Int?
    public var startNs: Int64?
    public var endNs: Int64?
    public var text: String?
    public var language: String?
    public var isFinal: Bool?
    public var timingQuality: TimingQuality?
    public var translationID: String?
    public var sourceRefs: [SourceRef]?
    public var gapReason: String?
    public var laneState: String?
    public var vocabularyCandidates: [VocabularyCorrectionCandidate]?

    public init(type: Kind, sessionID: String, laneID: String, captureEpoch: UInt64, providerEpoch: UInt64, eventID: String, segmentID: String? = nil, revision: Int? = nil, startNs: Int64? = nil, endNs: Int64? = nil, text: String? = nil, language: String? = nil, isFinal: Bool? = nil, timingQuality: TimingQuality? = nil, translationID: String? = nil, sourceRefs: [SourceRef]? = nil, gapReason: String? = nil, laneState: String? = nil) {
        self.schemaVersion = 1
        self.type = type
        self.sessionID = sessionID
        self.laneID = laneID
        self.captureEpoch = captureEpoch
        self.providerEpoch = providerEpoch
        self.eventID = eventID
        self.segmentID = segmentID
        self.revision = revision
        self.startNs = startNs
        self.endNs = endNs
        self.text = text
        self.language = language
        self.isFinal = isFinal
        self.timingQuality = timingQuality
        self.translationID = translationID
        self.sourceRefs = sourceRefs
        self.gapReason = gapReason
        self.laneState = laneState
    }
}

public struct SourceRef: Sendable, Codable, Equatable, Hashable {
    public var segmentID: String
    public var revision: Int
    public init(segmentID: String, revision: Int) {
        self.segmentID = segmentID
        self.revision = revision
    }
}

public enum TimingQuality: String, Sendable, Codable {
    case word
    case segment
    case estimated
    case unknown
}

/// What the presentation layer should do with a segment. Not a boolean (doc §11.3 #6).
public enum PresentationState: String, Sendable, Codable {
    /// Segment exists but has no text yet.
    case listening
    /// Source partial, may still change.
    case preview
    /// Source is stable (final or app-frozen), translation shown but not locked.
    case stable
    /// Source final, translation missing or stale.
    case awaitingTranslation
    /// Source final and translation final.
    case final
    /// Frozen by the app when its provider epoch ended. Never rewritten.
    case frozen
}

public struct CaptionTranslation: Sendable, Codable, Equatable {
    public var id: String
    public var text: String
    public var language: String?
    /// Highest source revision this translation was produced from.
    public var basedOnRevision: Int
    public var isFinal: Bool
    /// Set when the source moved past `basedOnRevision`; UI keeps showing it dimmed.
    public var isStale: Bool
    /// All segments this translation covers, in order. First one owns it.
    public var coveredSegmentIDs: [String]
    public var timingQuality: TimingQuality
    /// Per-source revisions prevent a late group translation from regressing a later
    /// correction to a non-owner sentence. Optional for older saved sessions.
    public var sourceRefs: [SourceRef]? = nil
}

public struct CaptionSegment: Sendable, Codable, Equatable, Identifiable {
    /// Stable key: lane / providerEpoch / provider segment id.
    public let id: String
    public let providerSegmentID: String
    public let laneID: String
    public let captureEpoch: UInt64
    public let providerEpoch: UInt64
    public var sourceText: String
    public var sourceRevision: Int
    public var sourceLanguage: String?
    public var sourceFinal: Bool
    public var startNs: Int64
    public var endNs: Int64
    public var timingQuality: TimingQuality
    public var translation: CaptionTranslation?
    /// When another segment's translation covers this one.
    public var mergedIntoTranslation: String?
    public var presentationState: PresentationState
    public var corrected: Bool
    /// Insertion order across the whole session, for stable listing.
    public let order: Int
    /// Previous source texts kept for correction history (bounded).
    public var history: [String]
    /// Set when the segment was frozen before the provider finalized it (session stopped, engine
    /// reconnected). The text shown is the last partial; it is neither a full sentence nor lost.
    public var incompleteReason: String?
    /// Optional for compatibility with archives saved before candidate review existed.
    public var vocabularyCandidates: [VocabularyCorrectionCandidate]? = nil
    /// First recognized sentence, retained even when bounded revision history rolls over.
    public var originalRecognitionText: String? = nil

    public var isIncomplete: Bool { incompleteReason != nil }
}

public struct CaptionGap: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var laneID: String
    public var captureEpoch: UInt64
    public var startNs: Int64
    public var endNs: Int64
    public var reason: String
    public let order: Int
    public var durationNs: Int64 { endNs - startNs }
}

public enum CaptionItem: Sendable, Equatable, Identifiable {
    case segment(CaptionSegment)
    case gap(CaptionGap)

    public var id: String {
        switch self {
        case .segment(let s): return s.id
        case .gap(let g): return g.id
        }
    }

    public var order: Int {
        switch self {
        case .segment(let s): return s.order
        case .gap(let g): return g.order
        }
    }

    public var laneID: String {
        switch self {
        case .segment(let s): return s.laneID
        case .gap(let g): return g.laneID
        }
    }
}

/// Immutable view handed to the UI at a limited rate.
public struct CaptionSnapshot: Sendable, Equatable {
    public var sessionID: String
    /// Monotonic counter, bumps on every applied change.
    public var version: UInt64
    public var items: [CaptionItem]
    public var laneStates: [String: String]
    public var activeProviderEpochs: [String: UInt64]

    public init(sessionID: String) {
        self.sessionID = sessionID
        self.version = 0
        self.items = []
        self.laneStates = [:]
        self.activeProviderEpochs = [:]
    }

    public var segments: [CaptionSegment] {
        items.compactMap { if case .segment(let s) = $0 { return s } else { return nil } }
    }

    public func segments(lane: String) -> [CaptionSegment] {
        segments.filter { $0.laneID == lane }
    }

    public func segment(id: String) -> CaptionSegment? {
        for item in items { if case .segment(let s) = item, s.id == id { return s } }
        return nil
    }

    /// Latest non-frozen segment of a lane: what the overlay shows as "current".
    public func currentSegment(lane: String) -> CaptionSegment? {
        segments(lane: lane).last
    }
}
