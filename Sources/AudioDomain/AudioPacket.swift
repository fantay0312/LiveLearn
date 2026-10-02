import Foundation

/// One block of captured audio with its place on the lane's monotonic timeline.
public struct AudioPacket: Sendable {
    public let laneID: String
    public let captureEpoch: UInt64
    public let sequence: UInt64
    /// Session-relative monotonic nanoseconds of the first frame.
    public let sourceStartNs: Int64
    /// Session-relative monotonic nanoseconds just after the last frame.
    public let sourceEndNs: Int64
    public let format: AudioFormatDescriptor
    public let samples: OwnedAudioBuffer
    /// True when the capture layer knows audio was lost immediately before this packet.
    public let discontinuityBefore: Bool

    public init(laneID: String, captureEpoch: UInt64, sequence: UInt64, sourceStartNs: Int64, sourceEndNs: Int64, format: AudioFormatDescriptor, samples: OwnedAudioBuffer, discontinuityBefore: Bool) {
        self.laneID = laneID
        self.captureEpoch = captureEpoch
        self.sequence = sequence
        self.sourceStartNs = sourceStartNs
        self.sourceEndNs = sourceEndNs
        self.format = format
        self.samples = samples
        self.discontinuityBefore = discontinuityBefore
    }

    public var durationNs: Int64 { sourceEndNs - sourceStartNs }
}

public enum GapReason: String, Sendable, Codable {
    case queueOverflow
    case deviceChange
    case sourceRestart
    case permissionLost
    case paused
    case network
    case captureStall
    /// Audio that was captured but the engine refused to accept (upload rejected / link down).
    case uploadFailed

    public var label: String {
        switch self {
        case .queueOverflow: return "队列溢出"
        case .deviceChange: return "设备切换"
        case .sourceRestart: return "来源重启"
        case .permissionLost: return "权限丢失"
        case .paused: return "已暂停"
        case .network: return "网络中断"
        case .captureStall: return "采集停滞"
        case .uploadFailed: return "未能上传"
        }
    }
}

/// An interval of source time that was not delivered downstream. Never silently compressed away.
public struct AudioGap: Sendable, Equatable, Codable {
    public let laneID: String
    public let captureEpoch: UInt64
    public let startNs: Int64
    public let endNs: Int64
    public let reason: GapReason

    public init(laneID: String, captureEpoch: UInt64, startNs: Int64, endNs: Int64, reason: GapReason) {
        self.laneID = laneID
        self.captureEpoch = captureEpoch
        self.startNs = startNs
        self.endNs = endNs
        self.reason = reason
    }

    public var durationNs: Int64 { endNs - startNs }
}

/// Observable capture health. Silence alone never decides the state (doc §6.5).
public enum CaptureState: String, Sendable, Codable {
    case idle
    case waitingForAudio
    case capturing
    case sourceIdle
    case sourceUnavailable
    case permissionRequired
    case recovering
    case stopped
    case failed
}

public struct CaptureHealth: Sendable, Equatable {
    public var laneID: String
    public var captureEpoch: UInt64
    public var state: CaptureState
    public var callbackCount: UInt64
    public var lastAudioNs: Int64?
    /// Latest RMS of the mono mixdown, 0...1.
    public var level: Float
    public var peak: Float
    public var format: AudioFormatDescriptor?
    public var queuedNs: Int64
    public var droppedNs: Int64
    public var detail: String?

    public init(laneID: String, captureEpoch: UInt64 = 0, state: CaptureState = .idle, callbackCount: UInt64 = 0, lastAudioNs: Int64? = nil, level: Float = 0, peak: Float = 0, format: AudioFormatDescriptor? = nil, queuedNs: Int64 = 0, droppedNs: Int64 = 0, detail: String? = nil) {
        self.laneID = laneID
        self.captureEpoch = captureEpoch
        self.state = state
        self.callbackCount = callbackCount
        self.lastAudioNs = lastAudioNs
        self.level = level
        self.peak = peak
        self.format = format
        self.queuedNs = queuedNs
        self.droppedNs = droppedNs
        self.detail = detail
    }
}

public struct CaptureFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case permissionDenied
        case sourceNotFound
        case deviceUnavailable
        case systemError
        case unsupported
    }
    public let kind: Kind
    public let message: String
    public let code: Int32?

    public init(kind: Kind, message: String, code: Int32? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    /// Interpolated into user-facing status text; the message alone, never the struct dump.
    public var description: String { message }
}

public enum CaptureEvent: Sendable {
    case started(epoch: UInt64, format: AudioFormatDescriptor)
    case packet(AudioPacket)
    case gap(AudioGap)
    case health(CaptureHealth)
    case stopped(epoch: UInt64)
    case failed(CaptureFailure)
}

/// Capture contract. `events` is consumed by exactly one router; fan-out is explicit and bounded elsewhere.
public protocol AudioCapture: AnyObject, Sendable {
    var laneID: String { get }
    /// Must not widen the user's chosen capture scope.
    func prepare(_ source: AudioSourceDescriptor) async throws
    func start() async throws
    func stop() async
    var events: AsyncStream<CaptureEvent> { get }
}
