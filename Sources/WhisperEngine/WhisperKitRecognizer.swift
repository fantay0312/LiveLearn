import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "whisper")

public struct WhisperConfig: Sendable, Equatable {
    public var variant: String

    public init(variant: String = WhisperVariant.defaultID) {
        self.variant = variant
    }
}

/// Open Whisper on this machine (WhisperKit, CoreML) as a pipeline stage. Nothing leaves the
/// machine; the model is a file the user downloaded on the 本地模型 page. Unlike Apple's
/// analyzer it works from macOS 15 and detects the language itself.
///
/// Whisper decodes clips, not streams: `UtteranceTracker` cuts the lane's packets into
/// utterances, each open utterance is re-decoded about once a second for the partial, and the
/// close of the utterance is the final. Timestamps are the clip's position on the session
/// timeline (the packets' own time), so they land on the caption axis directly.
public final class WhisperKitRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let stageID = "whisperkit"
    public static let sampleRate = 16_000

    public let config: WhisperConfig
    private let state: WhisperState

    /// `decoder` is for tests; the app lets the process cache hand one out per variant.
    public init(config: WhisperConfig, decoder: (any WhisperDecoder)? = nil, tracker: UtteranceTracker.Settings = UtteranceTracker.Settings()) {
        self.config = config
        self.state = WhisperState(variant: config.variant, decoder: decoder, tracker: tracker)
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: Self.stageID, displayName: "Whisper 本机识别", modelID: "whisperkit/\(WhisperVariant.label(for: config.variant))", isLocal: true, dataDestination: "本机处理，不联网", costUnit: "免费")
    }

    public var supportsAutoDetect: Bool { true }
    public var timingQuality: TimingQuality { .segment }

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        if !WhisperModelStore.isInstalled(config.variant) {
            return .blocked("Whisper 模型「\(WhisperVariant.label(for: config.variant))」尚未下载。在 设置 › 本地模型 中下载后即可开始。")
        }
        if let code = sourceLanguage, !WhisperLanguage.isSupported(code) {
            return .blocked("Whisper 不支持\(LanguageCatalog.name(code))；请换一种源语言或改用其他识别引擎。")
        }
        return .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        try await state.start(request)
    }

    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async { await state.flush() }
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }
}

/// The recognizer's state: the utterance cutter, the job queue and the worker that decodes.
/// The decoder is a separate actor, so a decode in flight never blocks `push`.
actor WhisperState {
    private enum Job {
        case partial(UtteranceTracker.Utterance)
        case final(UtteranceTracker.Utterance)

        var isFinal: Bool { if case .final = self { return true } else { return false } }
    }

    private let variant: String
    private let injected: (any WhisperDecoder)?
    private var decoder: (any WhisperDecoder)?
    private var tracker: UtteranceTracker
    private let trackerSettings: UtteranceTracker.Settings
    private var language: String?
    private var vocabulary: [String] = []
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var jobs: [Job] = []
    private var signal: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?
    /// A partial decode is running; a final may cut it short. A final in flight is never cut.
    private var busyPartial = false
    private var closed = true
    /// The last partial text shown for the open utterance, so a silent final can close it.
    private var shownPartial: String?
    private var laneID = ""
    /// This lane counts as a user of the process cache's model until it finishes or cancels.
    private var holdsCachedModel = false

    init(variant: String, decoder: (any WhisperDecoder)?, tracker: UtteranceTracker.Settings) {
        self.variant = variant
        self.injected = decoder
        self.trackerSettings = tracker
        self.tracker = UtteranceTracker(settings: tracker)
    }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        await teardown()
        let decoder: any WhisperDecoder
        if let injected {
            decoder = injected
        } else {
            decoder = await WhisperDecoderCache.shared.decoder(for: variant)
            await WhisperDecoderCache.shared.retain(variant)
            holdsCachedModel = true
        }
        do {
            try await decoder.load()
        } catch let e as WhisperDecoderError {
            await releaseCachedModel()
            switch e {
            case .modelMissing: throw ProviderError(.userFixable, "\(e.description)。在 设置 › 本地模型 中下载后即可开始。")
            case .loadFailed: throw ProviderError(.retryable, e.description)
            }
        } catch {
            await releaseCachedModel()
            throw ProviderError(.retryable, "Whisper 模型加载失败：\(error.localizedDescription)")
        }
        self.decoder = decoder
        language = request.sourceLanguage.map(WhisperLanguage.code)
        vocabulary = request.vocabulary
        laneID = request.laneID
        tracker = UtteranceTracker(settings: trackerSettings)
        jobs = []
        shownPartial = nil
        closed = false
        let (stream, cont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        events = cont
        let (sig, sigCont) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signal = sigCont
        worker = Task { [weak self] in await self?.run(sig) }
        log.notice("whisper open lane=\(request.laneID, privacy: .public) model=\(self.variant, privacy: .public) lang=\(self.language ?? "auto", privacy: .public)")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: Double(WhisperKitRecognizer.sampleRate), channelCount: 1), events: stream)
    }

    func push(_ packet: ProviderAudioPacket) {
        guard !closed else { return }
        let actions = tracker.ingest(samples: packet.mono, rms: packet.rms, startNs: packet.sourceStartNs, discontinuity: packet.discontinuityBefore)
        enqueue(actions)
    }

    /// Pause: close the open utterance now.
    func flush() {
        guard !closed else { return }
        if let a = tracker.flush() { enqueue([a]) }
    }

    func finish() async {
        guard !closed else { return }
        if let a = tracker.flush() { enqueue([a]) }
        signal?.finish()
        signal = nil
        // Let the worker drain the final decode, bounded; a large model on a long clip can
        // take a few seconds, and the session's own stop is bounded above us.
        if let worker {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await worker.value }
                group.addTask { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                await group.next()
                group.cancelAll()
            }
        }
        closed = true
        events?.finish()
        events = nil
        worker = nil
        await releaseCachedModel()
    }

    func cancel() async {
        closed = true
        decoder?.interrupt()
        await teardown()
        await releaseCachedModel()
    }

    /// Hands the shared model back to the cache, which unloads it after its grace period.
    private func releaseCachedModel() async {
        guard holdsCachedModel else { return }
        holdsCachedModel = false
        await WhisperDecoderCache.shared.release(variant)
    }

    private func enqueue(_ actions: [UtteranceTracker.Action]) {
        guard !actions.isEmpty else { return }
        for a in actions {
            switch a {
            case .partial(let u):
                // Newest partial wins; an older one still queued is stale.
                jobs.removeAll { !$0.isFinal }
                jobs.append(.partial(u))
            case .final(let u):
                jobs.removeAll { !$0.isFinal }
                jobs.append(.final(u))
                // A partial decode in flight is for this very utterance; cut it short. A final
                // in flight belongs to the previous sentence and must run to the end.
                if busyPartial { decoder?.interrupt() }
            }
        }
        signal?.yield()
    }

    private func nextJob() -> Job? {
        guard !jobs.isEmpty else { return nil }
        if let i = jobs.firstIndex(where: { $0.isFinal }) { return jobs.remove(at: i) }
        return jobs.removeFirst()
    }

    private func run(_ signal: AsyncStream<Void>) async {
        for await _ in signal {
            while !Task.isCancelled, let job = nextJob() {
                await perform(job)
            }
        }
        // The signal finished (finish): drain what is left.
        while !Task.isCancelled, let job = nextJob() {
            await perform(job)
        }
    }

    private func perform(_ job: Job) async {
        guard let decoder, !closed else { return }
        busyPartial = !job.isFinal
        defer { busyPartial = false }
        switch job {
        case .partial(let u):
            guard let result = try? await decoder.decode(u.samples, language: language, partial: true, vocabulary: vocabulary), !result.interrupted else { return }
            let text = WhisperTextFilter.text(of: result)
            guard !text.isEmpty, !closed else { return }
            shownPartial = text
            events?.yield(.chunk(TranscriptChunk(startNs: u.startNs, endNs: u.endNs, text: text, isFinal: false)))
        case .final(let u):
            let result: WhisperDecodeResult
            do {
                result = try await decoder.decode(u.samples, language: language, partial: false, vocabulary: vocabulary)
            } catch {
                guard !closed else { return }
                log.error("whisper decode failed: \(String(describing: error), privacy: .public)")
                events?.yield(.failed(ProviderError(.retryable, "Whisper 识别出错：\(error.localizedDescription)")))
                return
            }
            guard !closed else { return }
            var text = WhisperTextFilter.text(of: result)
            if result.interrupted { text = shownPartial ?? "" }
            let hadPartial = shownPartial != nil
            shownPartial = nil
            // Silence after a shown guess closes the guess; silence with nothing shown is nothing.
            guard !text.isEmpty || hadPartial else { return }
            events?.yield(.chunk(TranscriptChunk(startNs: u.startNs, endNs: u.endNs, text: text, isFinal: true)))
        }
    }

    private func teardown() async {
        signal?.finish()
        signal = nil
        worker?.cancel()
        worker = nil
        jobs = []
        events?.finish()
        events = nil
    }
}
