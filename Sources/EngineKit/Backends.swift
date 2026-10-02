import Foundation
import AudioDomain
import CaptionDomain
import ProviderAdapters

/// What one stage of an engine is, in words the settings screen and the inspector can show.
/// Every stage (a recognizer or a translator) carries one; the pipeline combines two of them
/// into the provider's capability sheet.
public struct EngineStageDescriptor: Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var modelID: String
    /// Nothing leaves this machine while the stage runs.
    public var isLocal: Bool
    /// "本机处理，不联网" / "音频发送到 OpenAI（美国）".
    public var dataDestination: String
    public var costUnit: String

    public init(id: String, displayName: String, modelID: String, isLocal: Bool, dataDestination: String, costUnit: String) {
        self.id = id
        self.displayName = displayName
        self.modelID = modelID
        self.isLocal = isLocal
        self.dataDestination = dataDestination
        self.costUnit = costUnit
    }
}

/// Whether a stage can serve a direction right now, and if not, why, in the user's words.
public enum StageAvailability: Sendable, Equatable {
    case ready
    /// The user can fix it (download a model, paste a key, pick another language).
    case blocked(String)

    public var blocker: String? {
        if case .blocked(let s) = self { return s }
        return nil
    }
    public var isReady: Bool { self == .ready }
}

/// One recognizer session for one lane.
public struct RecognizerRequest: Sendable {
    public var sessionID: String
    public var laneID: String
    public var providerEpoch: UInt64
    /// nil means "detect it" and is only sent to recognizers that declare `supportsAutoDetect`.
    public var sourceLanguage: String?
    public var sourceKind: AudioSourceKind
    public var vocabulary: [String]

    public init(sessionID: String, laneID: String, providerEpoch: UInt64, sourceLanguage: String?, sourceKind: AudioSourceKind, vocabulary: [String] = []) {
        self.sessionID = sessionID
        self.laneID = laneID
        self.providerEpoch = providerEpoch
        self.sourceLanguage = sourceLanguage
        self.sourceKind = sourceKind
        self.vocabulary = vocabulary
    }
}

public enum RecognizerEvent: Sendable {
    /// A volatile or final piece of transcript on the session timeline.
    case chunk(TranscriptChunk)
    /// The recognizer lost its connection or model mid-session. Retryable errors make the
    /// lane reconnect (a fresh `start`); anything else fails the lane.
    case failed(ProviderError)
}

/// What `start` hands back: the format the lane must deliver, and the results as they come.
/// The stream finishes after `finish` (or `cancel`) has done its work.
public struct RecognizerStream: Sendable {
    public var inputFormat: AudioFormatDescriptor
    public var events: AsyncStream<RecognizerEvent>

    public init(inputFormat: AudioFormatDescriptor, events: AsyncStream<RecognizerEvent>) {
        self.inputFormat = inputFormat
        self.events = events
    }
}

/// Speech in, transcript chunks out. One instance serves one lane; `start` may be called
/// again after `finish` / `cancel` (a reconnect with a new provider epoch).
///
/// Timing contract: chunks are stamped in session nanoseconds. Recognizers that keep their
/// own clock anchor it to the first packet's `sourceStartNs` and say how sure they are
/// through the pipeline's `timingQuality`.
public protocol SpeechRecognizer: AnyObject, Sendable {
    var descriptor: EngineStageDescriptor { get }
    /// True when a nil source language is acceptable.
    var supportsAutoDetect: Bool { get }
    /// How trustworthy the chunk timestamps are.
    var timingQuality: TimingQuality { get }
    /// Read-only check before a session: assets on disk, key present, language in the sheet.
    func availability(sourceLanguage: String?) async -> StageAvailability
    func start(_ request: RecognizerRequest) async throws -> RecognizerStream
    func push(_ packet: ProviderAudioPacket) async
    /// The lane paused: close whatever is still volatile without ending the session.
    func finalizePending() async
    /// End of input: flush, emit trailing results, finish the stream. Bounded by the caller.
    func finish() async throws
    func cancel() async
}

/// Text in one language out in another. One instance serves one lane.
public protocol TextTranslator: AnyObject, Sendable {
    var supportsGlossary: Bool { get }
    /// Opt in only when finality cannot change the translation of identical input. The queue
    /// can then reuse a successful preview for the matching final source revision.
    var reusesPreviewForFinal: Bool { get }
    var descriptor: EngineStageDescriptor { get }
    /// Read-only check before a session.
    func availability(source: String?, target: String) async -> StageAvailability
    /// Called at every `open`; verifies the pair is usable now (language pack, key, reachability).
    func prepare(source: String?, target: String) async throws
    /// `isFinal` lets a paid backend treat previews differently from finals if it wants to.
    func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String
    func cancel()
}

public extension TextTranslator {
    var supportsGlossary: Bool { false }
    var reusesPreviewForFinal: Bool { false }
}

extension SpeechRecognizer {
    public var supportsAutoDetect: Bool { false }
    public var timingQuality: TimingQuality { .segment }
}
