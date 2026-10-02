import Foundation
import AudioDomain
import CaptionDomain
import ProviderAdapters

public enum SessionState: String, Sendable, Codable, Equatable {
    case idle
    case preparing
    case connecting
    case running
    case paused
    case reconnecting
    case degraded
    case draining
    case stopping
    case completed
    case failed

    public var isActive: Bool {
        switch self {
        case .running, .paused, .reconnecting, .degraded, .draining, .connecting, .preparing: return true
        default: return false
        }
    }
}

public enum ProviderLinkState: String, Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting
    case closed
    case failed
}

public struct LaneConfiguration: Sendable, Equatable, Identifiable {
    public var id: String
    public var source: AudioSourceDescriptor
    /// nil only when the provider verified auto-detect support.
    public var sourceLanguage: String?
    public var targetLanguage: String
    public var providerID: String

    public init(id: String, source: AudioSourceDescriptor, sourceLanguage: String?, targetLanguage: String, providerID: String) {
        self.id = id
        self.source = source
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.providerID = providerID
    }
}

/// Everything the UI needs to describe one lane truthfully.
public struct LaneStatus: Sendable, Equatable, Identifiable {
    public var id: String
    public var configuration: LaneConfiguration
    public var capture: CaptureHealth
    public var providerName: String
    public var providerEpoch: UInt64
    public var providerLink: ProviderLinkState
    public var reconnectAttempts: Int
    public var lastError: String?
    public var isUploading: Bool
    public var dataDestination: String
    /// Session-relative ns of the newest audio sent to the provider.
    public var sentWatermarkNs: Int64
    /// Session-relative ns of the newest audio captured.
    public var capturedWatermarkNs: Int64
    /// Nothing leaves the machine on this lane (both engine stages are local).
    public var isLocal: Bool

    public var backlogNs: Int64 { max(0, capturedWatermarkNs - sentWatermarkNs) }

    public init(id: String, configuration: LaneConfiguration, capture: CaptureHealth, providerName: String, providerEpoch: UInt64, providerLink: ProviderLinkState, reconnectAttempts: Int, lastError: String?, isUploading: Bool, dataDestination: String, sentWatermarkNs: Int64, capturedWatermarkNs: Int64, isLocal: Bool = true) {
        self.id = id
        self.configuration = configuration
        self.capture = capture
        self.providerName = providerName
        self.providerEpoch = providerEpoch
        self.providerLink = providerLink
        self.reconnectAttempts = reconnectAttempts
        self.lastError = lastError
        self.isUploading = isUploading
        self.dataDestination = dataDestination
        self.sentWatermarkNs = sentWatermarkNs
        self.capturedWatermarkNs = capturedWatermarkNs
        self.isLocal = isLocal
    }
}

public struct SessionSnapshot: Sendable, Equatable {
    public var sessionID: String
    public var state: SessionState
    public var captions: CaptionSnapshot
    public var lanes: [LaneStatus]
    public var startedAtHostNs: Int64?
    public var elapsedNs: Int64
    public var failure: String?
    /// Human-readable reason for the current state, e.g. "等待 Safari 发声".
    public var detail: String?

    public init(sessionID: String, state: SessionState, captions: CaptionSnapshot, lanes: [LaneStatus], startedAtHostNs: Int64?, elapsedNs: Int64, failure: String?, detail: String?) {
        self.sessionID = sessionID
        self.state = state
        self.captions = captions
        self.lanes = lanes
        self.startedAtHostNs = startedAtHostNs
        self.elapsedNs = elapsedNs
        self.failure = failure
        self.detail = detail
    }

    public static func empty(sessionID: String = "none") -> SessionSnapshot {
        SessionSnapshot(sessionID: sessionID, state: .idle, captions: CaptionSnapshot(sessionID: sessionID), lanes: [], startedAtHostNs: nil, elapsedNs: 0, failure: nil, detail: nil)
    }
}

/// Converts captured audio to what a provider accepts: mono at the provider's sample rate.
/// The lane creates one adapter per lane and calls it from a single task, in packet order.
public protocol AudioFormatAdapter: Sendable {
    func convert(_ packet: AudioPacket, to target: AudioFormatDescriptor) -> ProviderAudioPacket
}

/// Stateless conversion: mixes to mono and resamples each packet on its own. Sample counts are
/// exact per packet, but the resampler restarts at every packet boundary, so use
/// `ResamplingFormatAdapter` for a live stream; this one exists for one-shot conversion and tests.
public struct PassthroughFormatAdapter: AudioFormatAdapter {
    public init() {}
    public func convert(_ packet: AudioPacket, to target: AudioFormatDescriptor) -> ProviderAudioPacket {
        var mono = packet.samples.mixedToMono()
        let energy = packet.samples.energy()
        if target.sampleRate > 0, target.sampleRate != packet.format.sampleRate {
            var r = StreamingResampler(sourceRate: packet.format.sampleRate, targetRate: target.sampleRate)
            mono = r.process(mono)
        }
        return ProviderAudioPacket(
            sequence: packet.sequence,
            captureEpoch: packet.captureEpoch,
            sourceStartNs: packet.sourceStartNs,
            sourceEndNs: packet.sourceEndNs,
            format: AudioFormatDescriptor(sampleRate: target.sampleRate > 0 ? target.sampleRate : packet.format.sampleRate, channelCount: 1),
            mono: mono,
            discontinuityBefore: packet.discontinuityBefore,
            rms: energy.rms
        )
    }
}

/// Stateful conversion for a live lane: filter history and fractional phase carry across
/// packets, so consecutive packets join without clicks and the output sample count over time is
/// exactly `input × target / source`. Resets at a discontinuity or a new capture epoch.
public final class ResamplingFormatAdapter: AudioFormatAdapter, @unchecked Sendable {
    private let lock = NSLock()
    private var resampler: StreamingResampler?
    private var epoch: UInt64 = 0

    public init() {}

    public func convert(_ packet: AudioPacket, to target: AudioFormatDescriptor) -> ProviderAudioPacket {
        var mono = packet.samples.mixedToMono()
        let energy = packet.samples.energy()
        let targetRate = target.sampleRate > 0 ? target.sampleRate : packet.format.sampleRate
        if targetRate != packet.format.sampleRate {
            mono = lock.withLock {
                if resampler == nil || resampler!.sourceRate != packet.format.sampleRate || resampler!.targetRate != targetRate {
                    resampler = StreamingResampler(sourceRate: packet.format.sampleRate, targetRate: targetRate)
                    epoch = packet.captureEpoch
                } else if packet.discontinuityBefore || packet.captureEpoch != epoch {
                    resampler!.reset()
                    epoch = packet.captureEpoch
                }
                return resampler!.process(mono)
            }
        }
        return ProviderAudioPacket(
            sequence: packet.sequence,
            captureEpoch: packet.captureEpoch,
            sourceStartNs: packet.sourceStartNs,
            sourceEndNs: packet.sourceEndNs,
            format: AudioFormatDescriptor(sampleRate: targetRate, channelCount: 1),
            mono: mono,
            discontinuityBefore: packet.discontinuityBefore,
            rms: energy.rms
        )
    }
}
