import Foundation
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "pipeline")

/// A cascaded engine: any `SpeechRecognizer` → `SpeechSegmenter` → any `TextTranslator`.
/// Apple's on-device pair, a cloud recognizer with a local translator, a local Whisper with
/// a cloud model: all the same provider, differing only in the two stages handed in.
///
/// One instance serves one lane; every `open` builds a fresh recognizer session (the lane
/// reopens with a new provider epoch after a retryable failure). Nothing here knows how a
/// stage does its work; it only knows the contract in `Backends.swift`.
public final class PipelineProvider: TranslationProvider, @unchecked Sendable {
    public let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let lock = NSLock()
    private let recognizer: any SpeechRecognizer
    private let translator: any TextTranslator
    private let providerID: String
    private let displayName: String
    private let vocabulary: [String]
    private var session: PipelineLaneSession?
    private var inputFormat = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
    private var epoch: UInt64 = 0
    /// Translate the growing partial as well, so the reader sees a live (dimmed) translation.
    /// Off by default for paid translators; the app decides.
    public let translatesPartials: Bool
    /// Spacing between partial translations; longer for paid backends.
    public let partialIntervalNs: Int64

    public init(recognizer: any SpeechRecognizer, translator: any TextTranslator, providerID: String, displayName: String, translatesPartials: Bool = true, partialIntervalNs: Int64 = 700_000_000, vocabulary: [String] = []) {
        self.recognizer = recognizer
        self.translator = translator
        self.providerID = providerID
        self.displayName = displayName
        self.vocabulary = vocabulary
        self.translatesPartials = translatesPartials
        self.partialIntervalNs = partialIntervalNs
        var cont: AsyncStream<ProviderEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    deinit {
        continuation.finish()
    }

    public var recognizerDescriptor: EngineStageDescriptor { recognizer.descriptor }
    public var translatorDescriptor: EngineStageDescriptor { translator.descriptor }

    /// "本机处理，不联网" when both stages stay on the machine; otherwise who receives what.
    public static func dataDestination(recognizer r: EngineStageDescriptor, translator t: EngineStageDescriptor) -> String {
        switch (r.isLocal, t.isLocal) {
        case (true, true): return "本机处理，不联网"
        case (false, true): return "音频 → \(r.displayName)；翻译在本机"
        case (true, false): return "识别在本机；文本 → \(t.displayName)"
        case (false, false): return "音频 → \(r.displayName)；文本 → \(t.displayName)"
        }
    }

    public var capabilities: ProviderCapabilities {
        let format = lock.withLock { inputFormat }
        let r = recognizer.descriptor
        let t = translator.descriptor
        let local = r.isLocal && t.isLocal
        return ProviderCapabilities(
            providerID: providerID,
            displayName: displayName,
            adapterVersion: "0.2",
            modelID: "\(r.modelID) + \(t.modelID)",
            supportedLanguagePairs: Self.pairs,
            sourceAutoDetect: recognizer.supportsAutoDetect ? .supported : .unsupported,
            inputFormats: [format],
            preferredFrameDurationMs: 100,
            requiresContinuousAudio: r.isLocal ? .unsupported : .unverified,
            hasSourceTranscript: .supported,
            hasTargetTranscript: .supported,
            hasTranslatedAudio: .unsupported,
            sourceTiming: recognizer.timingQuality == .segment ? "segment" : "estimated",
            targetAlignment: "providerGroup",
            partialSemantics: "snapshot",
            finalization: "explicit",
            supportsResume: .unsupported,
            supportsGlossary: translator.supportsGlossary ? .supported : .unsupported,
            textOnlyMode: .supported,
            maxSessionDurationSec: nil,
            dataRegion: local ? "local" : "remote",
            dataDestination: Self.dataDestination(recognizer: r, translator: t),
            costUnit: local ? "免费" : [r.costUnit, t.costUnit].filter { !$0.isEmpty && $0 != "免费" }.joined(separator: " + "),
            isLocal: local
        )
    }

    /// Pairs are decided at run time by each stage; the sheet lists them as unverified.
    private static let pairs: [LanguagePair] = {
        var out: [LanguagePair] = []
        for s in LanguageCatalog.codes { for t in LanguageCatalog.codes where s != t { out.append(LanguagePair(s, t, .unverified)) } }
        return out
    }()

    /// Both stages' readiness for one direction, for the start gate. Read-only.
    public func availability(source: String?, target: String) async -> (recognizer: StageAvailability, translator: StageAvailability) {
        async let r = recognizer.availability(sourceLanguage: source)
        async let t = translator.availability(source: source, target: target)
        return await (r, t)
    }

    public func open(_ configuration: ProviderSessionConfiguration) async throws {
        if configuration.sourceLanguage == nil, !recognizer.supportsAutoDetect {
            throw ProviderError(.unsupported, "\(recognizer.descriptor.displayName)需要指定源语言，不支持自动检测")
        }
        if let source = configuration.sourceLanguage, source == configuration.targetLanguage {
            throw ProviderError(.unsupported, "源语言与目标语言相同")
        }
        if case .blocked(let why) = await recognizer.availability(sourceLanguage: configuration.sourceLanguage) {
            throw ProviderError(.userFixable, why)
        }
        if case .blocked(let why) = await translator.availability(source: configuration.sourceLanguage, target: configuration.targetLanguage) {
            throw ProviderError(.userFixable, why)
        }
        let old: PipelineLaneSession? = lock.withLock {
            let s = session
            session = nil
            return s
        }
        if let old { await old.cancel() }
        let fresh = PipelineLaneSession(configuration: configuration, recognizer: recognizer, translator: translator, continuation: continuation, translatesPartials: translatesPartials, partialIntervalNs: partialIntervalNs, vocabulary: vocabulary)
        let format = try await fresh.start()
        lock.withLock {
            session = fresh
            inputFormat = format
            epoch = configuration.providerEpoch
        }
        continuation.yield(.opened(providerEpoch: configuration.providerEpoch))
    }

    public func push(_ packet: ProviderAudioPacket) async throws {
        guard let s = lock.withLock({ session }) else { return }
        await s.push(packet)
    }

    public func finishInput() async throws {
        let (s, e) = lock.withLock { (session, epoch) }
        guard let s else {
            continuation.yield(.closed(providerEpoch: e))
            return
        }
        try await s.finish()
        continuation.yield(.closed(providerEpoch: e))
    }

    public func cancel() async {
        let s: PipelineLaneSession? = lock.withLock {
            let s = session
            session = nil
            return s
        }
        await s?.cancel()
    }

    public func setPaused(_ paused: Bool) {
        guard paused, let s = lock.withLock({ session }) else { return }
        // Close whatever the recognizer is still guessing: the reader should not stare at
        // "识别中" for the whole pause.
        Task { await s.finalizePending() }
    }
}

// MARK: - Per-open session

actor PipelineLaneSession {
    private let configuration: ProviderSessionConfiguration
    private let recognizer: any SpeechRecognizer
    private let translator: any TextTranslator
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let translatesPartials: Bool
    private let partialIntervalNs: Int64
    private let vocabulary: [String]
    private let vocabularyMatcher: VocabularyMatcher
    private let candidateGenerator: VocabularyCandidateGenerator

    private var segmenter = SpeechSegmenter()
    private var resultsTask: Task<Void, Never>?
    private var queue: TranslationQueue?
    private var lastCaptureEpoch: UInt64 = 1
    private var closed = false
    private var finishing = false
    private var streamFinished = false
    /// Counters for the log line at close; never the text.
    private var pushedPackets = 0
    private var resultCount = 0
    private var finalCount = 0

    init(configuration: ProviderSessionConfiguration, recognizer: any SpeechRecognizer, translator: any TextTranslator, continuation: AsyncStream<ProviderEvent>.Continuation, translatesPartials: Bool, partialIntervalNs: Int64, vocabulary: [String]) {
        self.configuration = configuration
        self.recognizer = recognizer
        self.translator = translator
        self.continuation = continuation
        self.translatesPartials = translatesPartials
        self.partialIntervalNs = partialIntervalNs
        self.vocabulary = vocabulary
        self.vocabularyMatcher = VocabularyMatcher(vocabulary.map { VocabularyTerm(source: $0, target: $0) })
        self.candidateGenerator = VocabularyCandidateGenerator(vocabulary: vocabulary)
    }

    private var context: SpeechSegmenter.Context {
        SpeechSegmenter.Context(sessionID: configuration.sessionID, laneID: configuration.laneID, providerEpoch: configuration.providerEpoch, captureEpoch: lastCaptureEpoch, sourceLanguage: configuration.sourceLanguage ?? LanguageCatalog.auto, targetLanguage: configuration.targetLanguage)
    }

    /// Starts both stages; returns the audio format the lane must deliver.
    func start() async throws -> AudioFormatDescriptor {
        let request = RecognizerRequest(sessionID: configuration.sessionID, laneID: configuration.laneID, providerEpoch: configuration.providerEpoch, sourceLanguage: configuration.sourceLanguage, sourceKind: configuration.sourceKind, vocabulary: vocabulary)
        let stream = try await recognizer.start(request)
        do {
            try await translator.prepare(source: configuration.sourceLanguage, target: configuration.targetLanguage)
        } catch {
            await recognizer.cancel()
            throw error
        }
        let queue = TranslationQueue(translator: translator, source: configuration.sourceLanguage, target: configuration.targetLanguage) { [weak self] request, text in
            await self?.emitTranslation(request, text: text)
        }
        await queue.setPartialInterval(ns: partialIntervalNs)
        await queue.onPermanentFailure { [weak self] error in
            await self?.translatorFailed(error)
        }
        self.queue = queue
        resultsTask = Task { [weak self] in
            for await event in stream.events {
                guard let self else { return }
                if Task.isCancelled { return }
                await self.handle(event)
            }
            await self?.noteStreamFinished()
        }
        log.notice("pipeline open lane=\(self.configuration.laneID, privacy: .public) \(self.configuration.sourceLanguage ?? "auto", privacy: .public)→\(self.configuration.targetLanguage, privacy: .public) \(self.recognizer.descriptor.id, privacy: .public)+\(self.translator.descriptor.id, privacy: .public) format=\(stream.inputFormat.sampleRate, privacy: .public) Hz")
        return stream.inputFormat
    }

    private func noteStreamFinished() { streamFinished = true }

    private func handle(_ event: RecognizerEvent) {
        switch event {
        case .chunk(let chunk):
            handle(chunk)
        case .failed(let error):
            guard !closed else { return }
            log.error("recognizer failed: \(error.message, privacy: .public)")
            continuation.yield(.disconnected(providerEpoch: configuration.providerEpoch, error: error))
        }
    }

    private func translatorFailed(_ error: ProviderError) {
        guard !closed else { return }
        continuation.yield(.disconnected(providerEpoch: configuration.providerEpoch, error: ProviderError(error.classification, "翻译引擎（\(translator.descriptor.displayName)）：\(error.message)")))
    }

    private func handle(_ chunk: TranscriptChunk) {
        var chunk = chunk
        chunk.text = vocabularyMatcher.replacing(in: chunk.text)
        resultCount += 1
        if chunk.isFinal {
            finalCount += 1
            log.notice("final #\(self.finalCount, privacy: .public) lane=\(self.configuration.laneID, privacy: .public) range=\(Double(chunk.startNs) / 1e9, privacy: .public)–\(Double(chunk.endNs) / 1e9, privacy: .public)s chars=\(chunk.text.count, privacy: .public)")
        }
        var out = segmenter.apply(chunk, context: context)
        let quality = recognizer.timingQuality
        if quality != .segment {
            for i in out.events.indices where out.events[i].timingQuality != nil { out.events[i].timingQuality = quality }
        }
        for var ev in out.events {
            if ev.type == .sourceFinal, let text = ev.text {
                ev.vocabularyCandidates = candidateGenerator.candidates(in: text)
            }
            continuation.yield(.caption(ev))
        }
        if let request = out.translation, request.isFinal || translatesPartials {
            let q = queue
            Task { await q?.enqueue(request) }
        }
    }

    private func emitTranslation(_ request: SpeechSegmenter.TranslationRequest, text: String) {
        guard !closed || request.isFinal else { return }
        let ev = segmenter.translationEvent(for: request, text: text, context: context)
        continuation.yield(.caption(ev))
    }

    /// Awaited in order: the lane forwards packets one at a time, and a recognizer must see
    /// them in that order (a detached task per packet would let them overtake each other).
    func push(_ packet: ProviderAudioPacket) async {
        guard !closed else { return }
        lastCaptureEpoch = packet.captureEpoch
        pushedPackets += 1
        if pushedPackets == 1 || pushedPackets % 300 == 0 {
            log.notice("push #\(self.pushedPackets, privacy: .public) lane=\(self.configuration.laneID, privacy: .public) frames=\(packet.mono.count, privacy: .public) rms=\(packet.rms, privacy: .public)")
        }
        await recognizer.push(packet)
    }

    /// Pause: finalize what has been heard so far without ending the session.
    func finalizePending() async {
        guard !closed else { return }
        await recognizer.finalizePending()
    }

    /// Flush: end input, finalize, wait for trailing results and translations. Every wait is
    /// bounded so a recognizer that never got audio (or hangs) cannot hold the session's stop.
    func finish() async throws {
        guard !closed, !finishing else { return }
        finishing = true
        let finished = await Self.withTimeout(ns: 2_500_000_000) { [recognizer] in
            do {
                try await recognizer.finish()
            } catch {
                log.error("recognizer finish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !finished {
            log.error("recognizer finish timed out; cancelling")
            await recognizer.cancel()
        }
        await Self.wait(for: resultsTask, upToNs: 1_000_000_000)
        await queue?.drain(upToNs: 1_500_000_000)
        closed = true
        log.notice("pipeline closed lane=\(self.configuration.laneID, privacy: .public) packets=\(self.pushedPackets, privacy: .public) results=\(self.resultCount, privacy: .public) finals=\(self.finalCount, privacy: .public)")
    }

    /// Runs `body`, returning false when it did not complete within `ns`.
    private static func withTimeout(ns: UInt64, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await body(); return true }
            group.addTask { try? await Task.sleep(nanoseconds: ns); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func cancel() async {
        closed = true
        resultsTask?.cancel()
        await queue?.cancel()
        await recognizer.cancel()
    }

    private static func wait(for task: Task<Void, Never>?, upToNs: UInt64) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: upToNs) }
            await group.next()
            group.cancelAll()
        }
    }
}
