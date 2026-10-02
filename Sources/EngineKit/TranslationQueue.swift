import Foundation
import os
import AudioDomain
import ProviderAdapters

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "translation-queue")

/// Serial translation for one lane. Finals go first, in order; at most one partial is in
/// flight and partials are rate limited, so a fast talker cannot queue up stale guesses and a
/// paid backend never sees more than one preview per interval.
public actor TranslationQueue {
    public typealias Emit = @Sendable (SpeechSegmenter.TranslationRequest, String) async -> Void

    private let translator: any TextTranslator
    private let source: String?
    private let target: String
    private let emit: Emit
    private var finals: [SpeechSegmenter.TranslationRequest] = []
    private var partial: SpeechSegmenter.TranslationRequest?
    private var worker: Task<Void, Never>?
    /// Preview throttling must not occupy the serial translation worker: a final can wake
    /// it immediately without cancelling the translator's live session.
    private var throttleWake: Task<Void, Never>?
    private var throttleGeneration: UInt64 = 0
    private var lastPartialStartNs: Int64 = 0
    private var cancelled = false
    private var consecutiveFailures = 0
    /// One-entry, per-lane cache; never transfers text between sessions or backends.
    private var lastPreview: (segmentID: String, sourceText: String, translated: String)?
    /// Minimum spacing between partial translations of one lane.
    public var partialIntervalNs: Int64 = 700_000_000
    /// Set when the backend fails for good (an auth error, say): the lane is told once.
    private var reportedFailure: ((ProviderError) async -> Void)?

    public init(translator: any TextTranslator, source: String?, target: String, emit: @escaping Emit) {
        self.translator = translator
        self.source = source
        self.target = target
        self.emit = emit
    }

    public func setPartialInterval(ns: Int64) { partialIntervalNs = ns }

    public func onPermanentFailure(_ handler: @escaping @Sendable (ProviderError) async -> Void) {
        reportedFailure = handler
    }

    public func enqueue(_ request: SpeechSegmenter.TranslationRequest) {
        guard !cancelled else { return }
        if request.isFinal {
            finals.append(request)
            cancelThrottle()
            // A final supersedes any pending partial of the same segment.
            if partial?.segmentID == request.segmentID { partial = nil }
        } else {
            partial = request
        }
        kick()
    }

    private func kick() {
        guard worker == nil, !cancelled else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !cancelled && !Task.isCancelled {
            if !finals.isEmpty {
                let f = finals.removeFirst()
                await translate(f)
                continue
            }
            guard let p = partial else { break }
            let now = MonotonicClock.nowNs()
            let due = lastPartialStartNs + partialIntervalNs
            if now < due {
                scheduleThrottle(until: due)
                break
            }
            partial = nil
            lastPartialStartNs = MonotonicClock.nowNs()
            await translate(p)
        }
        worker = nil
    }

    private func scheduleThrottle(until due: Int64) {
        guard throttleWake == nil else { return }
        throttleGeneration &+= 1
        let generation = throttleGeneration
        throttleWake = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, due - MonotonicClock.nowNs()))) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.resumeAfterThrottle(generation: generation)
        }
    }

    private func resumeAfterThrottle(generation: UInt64) {
        guard generation == throttleGeneration, !cancelled else { return }
        throttleWake = nil
        kick()
    }

    private func cancelThrottle() {
        throttleGeneration &+= 1
        throttleWake?.cancel()
        throttleWake = nil
    }

    private func translate(_ request: SpeechSegmenter.TranslationRequest) async {
        do {
            if request.isFinal, translator.reusesPreviewForFinal, let cached = lastPreview,
               cached.segmentID == request.segmentID, cached.sourceText == request.text {
                lastPreview = nil
                guard !cancelled, !Task.isCancelled else { return }
                await emit(request, cached.translated)
                return
            }
            let translated = try await translator.translate(request.text, source: source, target: target, isFinal: request.isFinal)
            consecutiveFailures = 0
            guard !cancelled, !Task.isCancelled, !translated.isEmpty else { return }
            if !request.isFinal && translator.reusesPreviewForFinal {
                lastPreview = (request.segmentID, request.text, translated)
            } else {
                lastPreview = nil
            }
            await emit(request, translated)
        } catch is CancellationError {
            return
        } catch let error as ProviderError where error.classification != .retryable {
            // Wrong key, unsupported pair: retrying will not help; tell the lane once.
            log.error("translate failed for good: \(error.message, privacy: .public)")
            cancelled = true
            finals.removeAll()
            partial = nil
            if let handler = reportedFailure {
                reportedFailure = nil
                await handler(error)
            }
        } catch {
            guard !cancelled, !Task.isCancelled else { return }
            consecutiveFailures += 1
            log.error("translate failed (\(self.consecutiveFailures, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            if request.isFinal, consecutiveFailures <= 2 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !cancelled, !Task.isCancelled else { return }
                if let translated = try? await translator.translate(request.text, source: source, target: target, isFinal: true), !translated.isEmpty, !cancelled, !Task.isCancelled {
                    consecutiveFailures = 0
                    await emit(request, translated)
                }
            }
        }
    }

    /// Waits until queued finals are done (bounded). Partials are dropped.
    public func drain(upToNs: Int64) async {
        partial = nil
        cancelThrottle()
        let deadline = MonotonicClock.nowNs() + upToNs
        while (worker != nil || !finals.isEmpty), MonotonicClock.nowNs() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    public func cancel() {
        cancelled = true
        lastPreview = nil
        finals.removeAll()
        partial = nil
        cancelThrottle()
        worker?.cancel()
        translator.cancel()
    }
}
