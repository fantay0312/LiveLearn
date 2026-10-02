import Foundation
import AudioDomain
import CaptionDomain
import SessionDomain

/// The on-disk shape of one session: enough to reopen it in the reading column and to export
/// it, nothing that only matters while it runs (queues, levels, links). Versioned so a later
/// build can still read today's files.
public struct SessionArchive: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public enum Outcome: String, Codable, Sendable {
        case completed
        case failed
        /// The app did not reach a terminal state (crash, force quit); restored from a checkpoint.
        case interrupted
    }

    public struct Lane: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: String
        public var displayName: String
        public var bundleIdentifier: String?
        public var deviceUID: String?
        public var sourceLanguage: String?
        public var targetLanguage: String
        public var providerName: String
        public var dataDestination: String
        /// All applications of a multi-app source; absent in archives written before it existed.
        public var bundleIdentifiers: [String]?
        /// Both engine stages stayed on the machine; absent in older archives (which were always local).
        public var isLocal: Bool?

        public init(id: String, kind: String, displayName: String, bundleIdentifier: String?, deviceUID: String?, sourceLanguage: String?, targetLanguage: String, providerName: String, dataDestination: String, bundleIdentifiers: [String]? = nil, isLocal: Bool? = nil) {
            self.id = id
            self.kind = kind
            self.displayName = displayName
            self.bundleIdentifier = bundleIdentifier
            self.deviceUID = deviceUID
            self.sourceLanguage = sourceLanguage
            self.targetLanguage = targetLanguage
            self.providerName = providerName
            self.dataDestination = dataDestination
            self.bundleIdentifiers = bundleIdentifiers
            self.isLocal = isLocal
        }

        public var sourceKind: AudioSourceKind { AudioSourceKind(rawValue: kind) ?? .system }
        public var label: String { sourceKind.label }
    }

    public enum Item: Codable, Sendable, Equatable {
        case segment(CaptionSegment)
        case gap(CaptionGap)

        private enum CodingKeys: String, CodingKey { case type, segment, gap }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "segment": self = .segment(try c.decode(CaptionSegment.self, forKey: .segment))
            case "gap": self = .gap(try c.decode(CaptionGap.self, forKey: .gap))
            case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown item type \(other)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .segment(let s):
                try c.encode("segment", forKey: .type)
                try c.encode(s, forKey: .segment)
            case .gap(let g):
                try c.encode("gap", forKey: .type)
                try c.encode(g, forKey: .gap)
            }
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationNs: Int64
    public var outcome: Outcome
    public var failure: String?
    public var appVersion: String
    public var lanes: [Lane]
    public var items: [Item]

    public init(schemaVersion: Int = SessionArchive.currentSchemaVersion, id: String, title: String, startedAt: Date, endedAt: Date?, durationNs: Int64, outcome: Outcome, failure: String?, appVersion: String, lanes: [Lane], items: [Item]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationNs = durationNs
        self.outcome = outcome
        self.failure = failure
        self.appVersion = appVersion
        self.lanes = lanes
        self.items = items
    }

    // MARK: Derived

    public var segments: [CaptionSegment] {
        items.compactMap { if case .segment(let s) = $0 { return s } else { return nil } }
    }

    /// Sentences that reached a final state.
    public var segmentCount: Int { segments.filter { !$0.isIncomplete }.count }
    /// Sentences frozen before the engine finalized them.
    public var incompleteCount: Int { segments.filter(\.isIncomplete).count }
    public var gapCount: Int { items.filter { if case .gap = $0 { return true } else { return false } }.count }
    public var isEmpty: Bool { segments.isEmpty }

    public func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }

    // MARK: Conversion

    /// Captures a snapshot at (or near) its end. `outcome` is decided by the caller: a
    /// checkpoint of a running session is written as `.interrupted` so that, if it is ever read
    /// back, it says the truth.
    public init(snapshot: SessionSnapshot, title: String, startedAt: Date, outcome: Outcome, appVersion: String) {
        self.init(
            id: snapshot.sessionID,
            title: title,
            startedAt: startedAt,
            endedAt: outcome == .interrupted ? nil : startedAt.addingTimeInterval(Double(snapshot.elapsedNs) / 1_000_000_000),
            durationNs: snapshot.elapsedNs,
            outcome: outcome,
            failure: snapshot.failure,
            appVersion: appVersion,
            lanes: snapshot.lanes.map { l in
                Lane(id: l.id, kind: l.configuration.source.kind.rawValue, displayName: l.configuration.source.displayName, bundleIdentifier: l.configuration.source.bundleIdentifier, deviceUID: l.configuration.source.deviceUID, sourceLanguage: l.configuration.sourceLanguage, targetLanguage: l.configuration.targetLanguage, providerName: l.providerName, dataDestination: l.dataDestination, bundleIdentifiers: l.configuration.source.bundleIdentifiers, isLocal: l.isLocal)
            },
            items: snapshot.captions.items.map { item in
                switch item {
                case .segment(let s): return .segment(s)
                case .gap(let g): return .gap(g)
                }
            }
        )
    }

    /// A snapshot the reading column can show: stopped lanes, closed links, frozen captions.
    /// Nothing in it is live.
    public func displaySnapshot() -> SessionSnapshot {
        var captions = CaptionSnapshot(sessionID: id)
        captions.items = items.map { item in
            switch item {
            case .segment(let s): return .segment(s)
            case .gap(let g): return .gap(g)
            }
        }
        captions.version = UInt64(items.count)
        let lanes: [LaneStatus] = self.lanes.map { l in
            let source = AudioSourceDescriptor(kind: l.sourceKind, deviceUID: l.deviceUID, bundleIdentifier: l.bundleIdentifier, applicationPath: nil, displayName: l.displayName, bundleIdentifiers: l.bundleIdentifiers)
            let config = LaneConfiguration(id: l.id, source: source, sourceLanguage: l.sourceLanguage, targetLanguage: l.targetLanguage, providerID: "archived")
            return LaneStatus(id: l.id, configuration: config, capture: CaptureHealth(laneID: l.id, state: .stopped), providerName: l.providerName, providerEpoch: 0, providerLink: .closed, reconnectAttempts: 0, lastError: nil, isUploading: false, dataDestination: l.dataDestination, sentWatermarkNs: 0, capturedWatermarkNs: 0, isLocal: l.isLocal ?? true)
        }
        let state: SessionState = outcome == .failed ? .failed : .completed
        let detail: String? = outcome == .interrupted ? "上次未正常结束，从自动保存恢复" : nil
        return SessionSnapshot(sessionID: id, state: state, captions: captions, lanes: lanes, startedAtHostNs: nil, elapsedNs: durationNs, failure: failure, detail: detail)
    }
}
