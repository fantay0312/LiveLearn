import Foundation
import AudioDomain
import CaptionDomain

/// Scripted provider. Runs entirely locally, sends nothing anywhere, and produces the
/// same failure shapes a real provider would: partials, finals, late translations,
/// duplicates, disconnects and stale-epoch events.
public final class FakeProvider: TranslationProvider, @unchecked Sendable {
    public let capabilities: ProviderCapabilities
    public let events: AsyncStream<ProviderEvent>

    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let script: FakeScript
    private let lock = NSLock()
    private var configuration: ProviderSessionConfiguration?
    private var task: Task<Void, Never>?
    private var lastVoiceNs: Int64 = 0
    private var pushedNs: Int64 = 0
    private var cancelled = false
    /// Pause bookkeeping: the schedule is shifted by the total time spent paused.
    private var pausedAtNs: Int64?
    private var pauseOffsetNs: Int64 = 0
    /// Multiplies script timing; 1.0 = as written.
    public var speed: Double = 1.0
    /// RMS above which audio counts as voice for `waitForVoice`.
    public var voiceThreshold: Float = 0.015

    public init(script: FakeScript, providerID: String = "fake.demo") {
        self.script = script
        var cont: AsyncStream<ProviderEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
        self.capabilities = ProviderCapabilities(
            providerID: providerID,
            displayName: "演示引擎",
            adapterVersion: "0.1",
            modelID: "scripted/\(script.name)",
            supportedLanguagePairs: [LanguagePair(script.sourceLanguage, script.targetLanguage, .supported)],
            sourceAutoDetect: .unsupported,
            inputFormats: [AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)],
            preferredFrameDurationMs: 100,
            requiresContinuousAudio: .unsupported,
            hasSourceTranscript: .supported,
            hasTargetTranscript: .supported,
            hasTranslatedAudio: .unsupported,
            sourceTiming: "segment",
            targetAlignment: "providerGroup",
            partialSemantics: "snapshot",
            finalization: "explicit",
            supportsResume: .unsupported,
            supportsGlossary: .unsupported,
            textOnlyMode: .supported,
            maxSessionDurationSec: nil,
            dataRegion: "local",
            dataDestination: "本地，不联网",
            costUnit: "免费",
            isLocal: true
        )
    }

    deinit {
        continuation.finish()
    }

    public let reconnectsInternally = true

    public func open(_ configuration: ProviderSessionConfiguration) async throws {
        // A script is one fixed language pair. Refuse anything else up front instead of playing
        // captions in a language the user did not ask for.
        guard capabilities.supports(source: configuration.sourceLanguage, target: configuration.targetLanguage) else {
            throw ProviderError(.unsupported, "演示引擎只支持 \(script.sourceLanguage) → \(script.targetLanguage)，当前设置为 \(configuration.sourceLanguage ?? "自动") → \(configuration.targetLanguage)")
        }
        task?.cancel()
        lock.withLock {
            self.configuration = configuration
            self.cancelled = false
            self.pausedAtNs = nil
            self.pauseOffsetNs = 0
        }
        continuation.yield(.opened(providerEpoch: configuration.providerEpoch))
        let steps = script.steps
        let speed = self.speed
        task = Task { [weak self] in
            guard let self else { return }
            let startNs = MonotonicClock.nowNs()
            var epoch = configuration.providerEpoch
            var previousEpoch: UInt64? = nil
            var counter = 0
            var offsetMs = 0  // accumulated waiting (voice gates, reconnects)
            for step in steps {
                if Task.isCancelled { return }
                if self.isCancelled { return }
                let dueNs = startNs + Int64(Double(step.atMs + offsetMs) * 1_000_000 / speed)
                // Wait in short slices so a pause freezes the schedule instead of letting the
                // timer keep producing sentences nobody is listening to.
                while true {
                    if Task.isCancelled || self.isCancelled { return }
                    let (paused, pausedNs) = self.pauseState()
                    if paused {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    let waitNs = dueNs + pausedNs - MonotonicClock.nowNs()
                    if waitNs <= 0 { break }
                    try? await Task.sleep(nanoseconds: UInt64(min(waitNs, 50_000_000)))
                }
                if Task.isCancelled || self.isCancelled { return }
                counter += 1
                let sessionOffset = self.sessionOffsetNs()
                func make(_ type: CaptionEvent.Kind, id: String?) -> CaptionEvent {
                    CaptionEvent(type: type, sessionID: configuration.sessionID, laneID: configuration.laneID, captureEpoch: 1, providerEpoch: epoch, eventID: id ?? "\(configuration.laneID)-e\(epoch)-\(counter)")
                }
                switch step {
                case .source(_, let seg, let rev, let text, let s, let e, let isFinal, let id):
                    var ev = make(isFinal ? .sourceFinal : .sourceReplace, id: id)
                    ev.segmentID = seg
                    ev.revision = rev
                    ev.text = text
                    ev.language = script.sourceLanguage
                    ev.isFinal = isFinal
                    ev.startNs = sessionOffset + Int64(s) * 1_000_000
                    ev.endNs = sessionOffset + Int64(e) * 1_000_000
                    ev.timingQuality = .segment
                    self.continuation.yield(.caption(ev))
                case .translation(_, let tid, let refs, let text, let isFinal, let id):
                    var ev = make(isFinal ? .translationFinal : .translationReplace, id: id)
                    ev.translationID = tid
                    ev.sourceRefs = refs
                    ev.text = text
                    ev.language = script.targetLanguage
                    ev.isFinal = isFinal
                    self.continuation.yield(.caption(ev))
                case .gap(_, let s, let e, let reason):
                    var ev = make(.laneGap, id: nil)
                    ev.startNs = sessionOffset + Int64(s) * 1_000_000
                    ev.endNs = sessionOffset + Int64(e) * 1_000_000
                    ev.gapReason = reason
                    self.continuation.yield(.caption(ev))
                case .disconnect(_, let after):
                    self.continuation.yield(.disconnected(providerEpoch: epoch, error: ProviderError(.retryable, "模拟网络中断")))
                    try? await Task.sleep(nanoseconds: UInt64(Double(after) * 1_000_000 / speed))
                    if Task.isCancelled || self.isCancelled { return }
                    previousEpoch = epoch
                    epoch += 1
                    offsetMs += after
                    self.continuation.yield(.opened(providerEpoch: epoch))
                case .staleFromPreviousEpoch(_, let seg, let rev, let text):
                    guard let prev = previousEpoch else { continue }
                    var ev = CaptionEvent(type: .sourceReplace, sessionID: configuration.sessionID, laneID: configuration.laneID, captureEpoch: 1, providerEpoch: prev, eventID: "stale-\(counter)")
                    ev.segmentID = seg
                    ev.revision = rev
                    ev.text = text
                    ev.isFinal = false
                    self.continuation.yield(.caption(ev))
                case .waitForVoice:
                    let waitStart = MonotonicClock.nowNs()
                    let pausedBefore = self.pauseState().pausedNs
                    while !Task.isCancelled && !self.isCancelled {
                        let (paused, _) = self.pauseState()
                        let last = self.lock.withLock { self.lastVoiceNs }
                        if !paused, last > 0, MonotonicClock.nowNs() - last < 400_000_000 { break }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    // Time spent paused inside the gate is already accounted for by pauseOffset.
                    let pausedDuring = self.pauseState().pausedNs - pausedBefore
                    offsetMs += Int((MonotonicClock.nowNs() - waitStart - pausedDuring) / 1_000_000)
                case .end:
                    self.continuation.yield(.closed(providerEpoch: epoch))
                    return
                }
            }
        }
    }

    public func push(_ packet: ProviderAudioPacket) async throws {
        lock.withLock {
            pushedNs += packet.sourceEndNs - packet.sourceStartNs
            if packet.rms > voiceThreshold { lastVoiceNs = MonotonicClock.nowNs() }
        }
    }

    public func finishInput() async throws {
        // Scripted provider has no trailing output to flush; report close promptly.
        let epoch = lock.withLock { configuration?.providerEpoch ?? 0 }
        task?.cancel()
        continuation.yield(.closed(providerEpoch: epoch))
    }

    public func cancel() async {
        lock.withLock { cancelled = true }
        task?.cancel()
    }

    public func setPaused(_ paused: Bool) {
        lock.withLock {
            if paused {
                if pausedAtNs == nil { pausedAtNs = MonotonicClock.nowNs() }
            } else if let since = pausedAtNs {
                pauseOffsetNs += MonotonicClock.nowNs() - since
                pausedAtNs = nil
            }
        }
    }

    /// Whether the script is paused, and the total pause time (including an ongoing pause).
    private func pauseState() -> (paused: Bool, pausedNs: Int64) {
        lock.withLock {
            let ongoing = pausedAtNs.map { MonotonicClock.nowNs() - $0 } ?? 0
            return (pausedAtNs != nil, pauseOffsetNs + ongoing)
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// The script measures time from `open`; the caption timeline is session-relative.
    private var openedSessionOffsetNs: Int64 = -1
    private func sessionOffsetNs() -> Int64 {
        lock.withLock {
            if openedSessionOffsetNs < 0 { openedSessionOffsetNs = 0 }
            return openedSessionOffsetNs
        }
    }

    /// Lets the lane coordinator tell the script where "now" is on the session timeline.
    public func setSessionOffset(ns: Int64) {
        lock.withLock { openedSessionOffsetNs = ns }
    }

    public func noteSessionTime(ns: Int64) {
        setSessionOffset(ns: ns)
    }
}
