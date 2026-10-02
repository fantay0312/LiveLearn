// ASR payload normalize, two-pass pick, VAD timeline, unique session-final gate (spec §16–17).
import Foundation

public struct TranscriptEvent: Equatable, Sendable {
    public var text: String
    public var isFinal: Bool
    public var seqId: Int64 = 0
    public var startTime: Double = 0
    public var endTime: Double = 0
    public var vadFinished: Bool = false
    public var streamFinished: Bool = false
    public var raw: JSONValue? = nil
    public var resultCount: Int = 0
    public var isInterim: Bool = true

    public init(text: String, isFinal: Bool, seqId: Int64 = 0, startTime: Double = 0, endTime: Double = 0,
                vadFinished: Bool = false, streamFinished: Bool = false, raw: JSONValue? = nil,
                resultCount: Int = 0, isInterim: Bool = true) {
        self.text = text
        self.isFinal = isFinal
        self.seqId = seqId
        self.startTime = startTime
        self.endTime = endTime
        self.vadFinished = vadFinished
        self.streamFinished = streamFinished
        self.raw = raw
        self.resultCount = resultCount
        self.isInterim = isInterim
    }
}

public enum TranscriptError: Error, CustomStringConvertible {
    case notJSON(String)
    public var description: String { switch self { case .notJSON(let m): return "payload is not JSON: \(m)" } }
}

/// Python `_as_float`: None/bool → default; numbers → float; strings via float() else default.
func asFloat(_ v: JSONValue?, _ def: Double = 0) -> Double {
    switch v {
    case .int(let i)?: return Double(i)
    case .double(let d)?: return d
    case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)) ?? def
    default: return def
    }
}

/// Python `_as_int`: bool/None → default; int → int; else int(value) (truncating floats,
/// parsing decimal strings) else default.
func asInt(_ v: JSONValue?, _ def: Int64 = 0) -> Int64 {
    switch v {
    case .int(let i)?: return i
    case .double(let d)?: return d.isFinite && abs(d) < 9.2e18 ? Int64(d) : def
    case .string(let s)?: return Int64(s.trimmingCharacters(in: .whitespaces)) ?? def
    default: return def
    }
}

private func seqFrom(result: JSONObject, payload: JSONObject, envelopeSeq: Int64) -> Int64 {
    if let extra = result["extra"]?.objectValue, extra.has("seq_id") {
        return asInt(extra["seq_id"], envelopeSeq)
    }
    if let extra = payload["extra"]?.objectValue, extra.has("seq_id") {
        return asInt(extra["seq_id"], envelopeSeq)
    }
    return envelopeSeq
}

/// Two-pass selection: last `is_interim=false`, else last result with a string `text`.
public func pickResult(_ results: [JSONValue]) -> JSONObject? {
    var lastFinal: JSONObject? = nil
    var lastWithText: JSONObject? = nil
    for item in results {
        guard let obj = item.objectValue else { continue }
        if obj["is_interim"] == .bool(false) { lastFinal = obj }
        if obj["text"]?.stringValue != nil { lastWithText = obj }
    }
    return lastFinal ?? lastWithText
}

public func normalizePayload(_ payload: [UInt8], envelopeSeq: Int64 = 0, streamFinished: Bool = false) throws -> TranscriptEvent? {
    if payload.isEmpty { return nil }
    // Python strips whitespace before the emptiness check.
    var allWS = true
    for b in payload where !(b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09) { allWS = false; break }
    if allWS { return nil }
    let obj: JSONValue
    do { obj = try JSONParser.parse(payload) } catch { throw TranscriptError.notJSON("\(error)") }
    return normalizePayload(obj, envelopeSeq: envelopeSeq, streamFinished: streamFinished)
}

public func normalizePayload(_ value: JSONValue, envelopeSeq: Int64 = 0, streamFinished: Bool = false) -> TranscriptEvent? {
    guard let obj = value.objectValue else { return nil }
    let results = obj["results"]?.arrayValue ?? []
    guard let chosen = pickResult(results), let text = chosen["text"]?.stringValue else { return nil }
    let extra = chosen["extra"]?.objectValue ?? JSONObject()
    if text.isEmpty && !extra.has("vad_start") { return nil }
    let isInterim = chosen["is_interim"]
    let vadFinished = chosen["is_vad_finished"]?.pythonTruthy ?? false
    let isFinal = isInterim == .bool(false) || vadFinished
    var count = 0
    for r in results where r.objectValue != nil { count += 1 }
    return TranscriptEvent(
        text: text,
        isFinal: isFinal,
        seqId: seqFrom(result: chosen, payload: obj, envelopeSeq: envelopeSeq),
        startTime: asFloat(chosen["start_time"]),
        endTime: asFloat(chosen["end_time"]),
        vadFinished: vadFinished || isInterim == .bool(false),
        streamFinished: streamFinished,
        raw: value,
        resultCount: count,
        isInterim: !isFinal
    )
}

public func passName(_ resultCount: Int) -> String {
    if resultCount >= 3 { return "three" }
    if resultCount == 2 { return "two" }
    return "one"
}

public func candidateGroups(_ raw: JSONValue?) -> [JSONValue] {
    guard let results = raw?.objectValue?["results"]?.arrayValue else { return [] }
    var groups: [JSONValue] = []
    for (index, item) in results.enumerated() {
        guard let obj = item.objectValue else { continue }
        let start = asFloat(obj["start_time"])
        var end = asFloat(obj["end_time"])
        if end < start { end = start }
        var group = JSONObject([
            ("index", .int(Int64(index))),
            ("start_time", .double(start)),
            ("end_time", .double(end)),
            ("source_text", .string(obj["text"]?.stringValue ?? "")),
            ("nbest", .array([])),
            ("highwords", .array([])),
            ("userwords", .array([])),
        ])
        if let extra = obj["extra"]?.objectValue, extra.has("seq_id") {
            group["seq_id"] = .int(asInt(extra["seq_id"]))
        }
        groups.append(.object(group))
    }
    return groups
}

public struct VADKey: Hashable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
}

public func vadKey(_ event: TranscriptEvent) -> VADKey { VADKey(text: event.text, start: event.startTime, end: event.endTime) }

public struct TranscriptTimeline: Sendable {
    public private(set) var committedSegments: [String] = []
    public private(set) var currentHypothesis: String = ""
    public private(set) var latestEvent: TranscriptEvent? = nil
    public private(set) var seenFinalKeys: Set<VADKey> = []
    private var segments: [TranscriptEvent] = []

    public init() {}

    public var committedText: String { committedSegments.joined() }
    public var text: String { committedText + currentHypothesis }

    @discardableResult
    public mutating func update(_ event: TranscriptEvent) -> String {
        if let latestEvent, event.seqId > 0, latestEvent.seqId > event.seqId { return text }
        latestEvent = event
        if event.isFinal || event.vadFinished {
            let key = vadKey(event)
            if segments.last.map({ vadKey($0) == key }) == true { return text }
            segments.removeAll { $0.startTime >= event.startTime || $0.endTime > event.startTime }
            segments.append(event)
            committedSegments = segments.map(\.text)
            seenFinalKeys = Set(segments.map(vadKey))
            currentHypothesis = ""
            return text
        }
        let committed = committedText
        if !committed.isEmpty && event.text.unicodeScalars.starts(with: committed.unicodeScalars) {
            let scalars = Array(event.text.unicodeScalars)
            currentHypothesis = String(String.UnicodeScalarView(scalars[committed.unicodeScalars.count...]))
        } else {
            // A revision with the same audio range replaces that range, even if its spelling
            // no longer shares a prefix (扣德克斯 -> Codex). Distinct later ranges append.
            segments.removeAll { $0.startTime >= event.startTime || $0.endTime > event.startTime }
            committedSegments = segments.map(\.text)
            currentHypothesis = event.text
        }
        return text
    }
}

public struct SessionFinalGate: Sendable {
    public private(set) var localFinishReceived = false
    public private(set) var remoteSessionFinished = false
    public private(set) var finalSent = false

    public init() {}
    public mutating func markLocalFinish() { localFinishReceived = true }
    public mutating func markRemoteFinished() { remoteSessionFinished = true }
    public func canEmit() -> Bool { localFinishReceived && remoteSessionFinished && !finalSent }
    public mutating func markSent() { finalSent = true }
}
