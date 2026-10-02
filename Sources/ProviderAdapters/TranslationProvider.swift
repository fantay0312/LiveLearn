import Foundation
import AudioDomain
import CaptionDomain

public enum Capability: String, Sendable, Codable {
    case supported
    case unsupported
    case unverified
}

public struct LanguagePair: Sendable, Codable, Hashable {
    public var source: String
    public var target: String
    public var status: Capability
    public init(_ source: String, _ target: String, _ status: Capability) {
        self.source = source
        self.target = target
        self.status = status
    }
}

/// Versioned capability sheet. Unknown values are `unverified`, never `supported`.
public struct ProviderCapabilities: Sendable, Codable {
    public var providerID: String
    public var displayName: String
    public var adapterVersion: String
    public var modelID: String
    public var supportedLanguagePairs: [LanguagePair]
    public var sourceAutoDetect: Capability
    public var inputFormats: [AudioFormatDescriptor]
    public var preferredFrameDurationMs: Int
    public var requiresContinuousAudio: Capability
    public var hasSourceTranscript: Capability
    public var hasTargetTranscript: Capability
    public var hasTranslatedAudio: Capability
    public var sourceTiming: String      // word | segment | none
    public var targetAlignment: String   // providerGroup | estimatedGroup | none
    public var partialSemantics: String  // append | replaceTail | snapshot
    public var finalization: String      // explicit | endpointBased | unavailable
    public var supportsResume: Capability
    public var supportsGlossary: Capability
    public var textOnlyMode: Capability
    public var maxSessionDurationSec: Int?
    public var dataRegion: String
    /// Where audio goes, in words the settings screen can show: "本地，不联网".
    public var dataDestination: String
    public var costUnit: String
    public var isLocal: Bool

    public init(providerID: String, displayName: String, adapterVersion: String, modelID: String, supportedLanguagePairs: [LanguagePair], sourceAutoDetect: Capability, inputFormats: [AudioFormatDescriptor], preferredFrameDurationMs: Int, requiresContinuousAudio: Capability, hasSourceTranscript: Capability, hasTargetTranscript: Capability, hasTranslatedAudio: Capability, sourceTiming: String, targetAlignment: String, partialSemantics: String, finalization: String, supportsResume: Capability, supportsGlossary: Capability, textOnlyMode: Capability, maxSessionDurationSec: Int?, dataRegion: String, dataDestination: String, costUnit: String, isLocal: Bool) {
        self.providerID = providerID
        self.displayName = displayName
        self.adapterVersion = adapterVersion
        self.modelID = modelID
        self.supportedLanguagePairs = supportedLanguagePairs
        self.sourceAutoDetect = sourceAutoDetect
        self.inputFormats = inputFormats
        self.preferredFrameDurationMs = preferredFrameDurationMs
        self.requiresContinuousAudio = requiresContinuousAudio
        self.hasSourceTranscript = hasSourceTranscript
        self.hasTargetTranscript = hasTargetTranscript
        self.hasTranslatedAudio = hasTranslatedAudio
        self.sourceTiming = sourceTiming
        self.targetAlignment = targetAlignment
        self.partialSemantics = partialSemantics
        self.finalization = finalization
        self.supportsResume = supportsResume
        self.supportsGlossary = supportsGlossary
        self.textOnlyMode = textOnlyMode
        self.maxSessionDurationSec = maxSessionDurationSec
        self.dataRegion = dataRegion
        self.dataDestination = dataDestination
        self.costUnit = costUnit
        self.isLocal = isLocal
    }
}

public struct ProviderSessionConfiguration: Sendable {
    public var sessionID: String
    public var laneID: String
    public var providerEpoch: UInt64
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var sourceKind: AudioSourceKind

    public init(sessionID: String, laneID: String, providerEpoch: UInt64, sourceLanguage: String?, targetLanguage: String, sourceKind: AudioSourceKind) {
        self.sessionID = sessionID
        self.laneID = laneID
        self.providerEpoch = providerEpoch
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceKind = sourceKind
    }
}

/// Audio already converted to the provider's accepted format.
public struct ProviderAudioPacket: Sendable {
    public var sequence: UInt64
    public var captureEpoch: UInt64
    public var sourceStartNs: Int64
    public var sourceEndNs: Int64
    public var format: AudioFormatDescriptor
    public var mono: [Float]
    public var discontinuityBefore: Bool
    public var rms: Float

    public init(sequence: UInt64, captureEpoch: UInt64, sourceStartNs: Int64, sourceEndNs: Int64, format: AudioFormatDescriptor, mono: [Float], discontinuityBefore: Bool, rms: Float) {
        self.sequence = sequence
        self.captureEpoch = captureEpoch
        self.sourceStartNs = sourceStartNs
        self.sourceEndNs = sourceEndNs
        self.format = format
        self.mono = mono
        self.discontinuityBefore = discontinuityBefore
        self.rms = rms
    }
}

public enum ProviderErrorClass: String, Sendable, Codable {
    case userFixable
    case retryable
    case unsupported
    case permanent
}

public struct ProviderError: Error, Sendable, Equatable, CustomStringConvertible {
    public var classification: ProviderErrorClass
    public var message: String
    public init(_ classification: ProviderErrorClass, _ message: String) {
        self.classification = classification
        self.message = message
    }
    /// Interpolated into user-facing status text; the message alone, never the struct dump.
    public var description: String { message }
}

public struct ProviderUsage: Sendable, Equatable {
    public var billedAudioNs: Int64
    public var connectionNs: Int64
    public init(billedAudioNs: Int64 = 0, connectionNs: Int64 = 0) {
        self.billedAudioNs = billedAudioNs
        self.connectionNs = connectionNs
    }
}

public enum ProviderEvent: Sendable {
    case opened(providerEpoch: UInt64)
    case caption(CaptionEvent)
    case disconnected(providerEpoch: UInt64, error: ProviderError)
    case closed(providerEpoch: UInt64)
    case usage(ProviderUsage)
}

public protocol TranslationProvider: AnyObject, Sendable {
    var capabilities: ProviderCapabilities { get }
    func open(_ configuration: ProviderSessionConfiguration) async throws
    func push(_ packet: ProviderAudioPacket) async throws
    /// Flush and wait for trailing output; the session then waits for `.closed`.
    func finishInput() async throws
    func cancel() async
    var events: AsyncStream<ProviderEvent> { get }
    /// True when the adapter re-opens its own connection after a retryable disconnect and
    /// emits `.opened` with a new provider epoch itself. Otherwise the lane coordinator reconnects.
    var reconnectsInternally: Bool { get }
    /// The lane stopped (or resumed) sending audio on purpose. Streaming providers need nothing
    /// here; time-driven ones (the scripted demo) must hold their schedule while paused.
    func setPaused(_ paused: Bool)
    /// Where "now" is on the session timeline when the provider is opened. Providers that stamp
    /// events from the audio they receive ignore this; time-driven ones anchor their clock here.
    func noteSessionTime(ns: Int64)
}

extension TranslationProvider {
    public var reconnectsInternally: Bool { false }
    public func setPaused(_ paused: Bool) {}
    public func noteSessionTime(ns: Int64) {}
}

extension ProviderCapabilities {
    public func supports(source: String?, target: String) -> Bool {
        guard let source else { return sourceAutoDetect == .supported }
        return supportedLanguagePairs.contains { $0.source == source && $0.target == target && $0.status == .supported }
    }
}
