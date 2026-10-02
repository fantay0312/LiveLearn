import Foundation
import os
import WhisperKit

/// One decoded window, in seconds relative to the samples handed in.
public struct WhisperSegment: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var noSpeechProb: Float
    public var avgLogprob: Float

    public init(start: Double, end: Double, text: String, noSpeechProb: Float = 0, avgLogprob: Float = 0) {
        self.start = start
        self.end = end
        self.text = text
        self.noSpeechProb = noSpeechProb
        self.avgLogprob = avgLogprob
    }
}

public struct WhisperDecodeResult: Sendable, Equatable {
    public var segments: [WhisperSegment]
    public var language: String?
    /// The decode was cut short by `interrupt()`; whatever came back is stale.
    public var interrupted: Bool

    public init(segments: [WhisperSegment], language: String? = nil, interrupted: Bool = false) {
        self.segments = segments
        self.language = language
        self.interrupted = interrupted
    }
}

/// What the recognizer needs from Whisper, so tests can script it and never load a model.
public protocol WhisperDecoder: AnyObject, Sendable {
    /// Loads the model; may take seconds the first time (CoreML compiles for this machine).
    func load() async throws
    /// Decodes 16 kHz mono samples. `partial` trades accuracy for speed (no temperature fallbacks).
    func decode(_ samples: [Float], language: String?, partial: Bool) async throws -> WhisperDecodeResult
    func decode(_ samples: [Float], language: String?, partial: Bool, vocabulary: [String]) async throws -> WhisperDecodeResult
    /// Stops the decode in flight at the next token; its result comes back marked `interrupted`.
    func interrupt()
    func unload() async
}

public extension WhisperDecoder {
    func decode(_ samples: [Float], language: String?, partial: Bool, vocabulary: [String]) async throws -> WhisperDecodeResult {
        try await decode(samples, language: language, partial: partial)
    }
}

/// The real thing. An actor so the (non-Sendable) `WhisperKit` object never leaves it; the
/// decode loop runs on this actor's executor, which is fine because nothing else lives here.
/// The recognizer's own state sits in a different actor and keeps taking audio meanwhile.
public actor WhisperKitDecoder: WhisperDecoder {
    public static let sampleRate = 16_000

    private let variant: String
    private let modelFolder: URL
    private let tokenizerFolder: URL
    private var kit: WhisperKit?
    private let stop = OSAllocatedUnfairLock(initialState: false)

    public init(variant: String) {
        self.variant = variant
        self.modelFolder = WhisperModelStore.folder(for: variant)
        self.tokenizerFolder = WhisperModelStore.downloadBase
    }

    public var isLoaded: Bool { kit != nil }

    public func load() async throws {
        if kit != nil { return }
        guard WhisperModelStore.isInstalled(variant) else {
            throw WhisperDecoderError.modelMissing(variant)
        }
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            kit = try await WhisperKit(config)
        } catch {
            throw WhisperDecoderError.loadFailed(String(describing: error))
        }
    }

    public nonisolated func interrupt() {
        stop.withLock { $0 = true }
    }

    public func decode(_ samples: [Float], language: String?, partial: Bool) async throws -> WhisperDecodeResult {
        try await decode(samples, language: language, partial: partial, vocabulary: [])
    }

    public func decode(_ samples: [Float], language: String?, partial: Bool, vocabulary: [String]) async throws -> WhisperDecodeResult {
        guard let kit else { throw WhisperDecoderError.modelMissing(variant) }
        stop.withLock { $0 = false }
        // Per-decode context: a cached model can serve lanes with different vocabularies.
        // Keep the first terms within WhisperKit's prompt budget; leave room for speech.
        let tokens = kit.tokenizer?.encode(text: vocabulary.joined(separator: ", ")) ?? []
        let prompt = Array(tokens.prefix(Constants.maxTokenContext / 2 - 1))
        // Whisper's quality gates drop a window that fails them once the fallbacks are used
        // up, and a clip then loses its last words (seen on the synthetic test voice, likely
        // on noisy rooms). A caption must not lose words, so the log-probability gates are
        // off for both decodes; the final keeps only the repetition gate (the classic
        // hallucination loop) with one retry, and the partial is fast and unguarded.
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperatureFallbackCount: partial ? 0 : 1,
            usePrefillPrompt: language != nil || !prompt.isEmpty,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: prompt.isEmpty ? nil : prompt,
            compressionRatioThreshold: partial ? nil : 2.4,
            logProbThreshold: nil,
            firstTokenLogProbThreshold: nil,
            chunkingStrategy: ChunkingStrategy.none
        )
        let stop = self.stop
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options, callback: { _ in
            // Returning false ends the current window at the next token.
            stop.withLock { $0 } ? false : nil
        })
        let interrupted = stop.withLock { $0 }
        var segments: [WhisperSegment] = []
        for r in results {
            for s in r.segments {
                segments.append(WhisperSegment(start: Double(s.start), end: Double(s.end), text: s.text, noSpeechProb: s.noSpeechProb, avgLogprob: s.avgLogprob))
            }
        }
        return WhisperDecodeResult(segments: segments, language: results.first?.language, interrupted: interrupted)
    }

    public func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

public enum WhisperDecoderError: Error, CustomStringConvertible, Sendable {
    case modelMissing(String)
    case loadFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let v): return "Whisper 模型「\(WhisperVariant.label(for: v))」尚未下载"
        case .loadFailed(let why): return "Whisper 模型加载失败：\(why)"
        }
    }
}

/// Loaded models are shared per variant while any lane uses them (a large one takes seconds to
/// load, and two lanes may run the same model). A model nobody is using any more is unloaded
/// after a grace period — long enough for the next session to start without a reload, short
/// enough that a gigabyte of CoreML weights does not sit in memory for the rest of the day —
/// and at once when the system reports memory pressure. Deleting a model evicts it.
public actor WhisperDecoderCache {
    public static let shared = WhisperDecoderCache()
    /// How long an unused model stays loaded before it is released.
    public static let idleGrace: Duration = .seconds(10 * 60)

    private var decoders: [String: WhisperKitDecoder] = [:]
    private var users: [String: Int] = [:]
    private var evictions: [String: Task<Void, Never>] = [:]
    private var pressure: DispatchSourceMemoryPressure?

    public func decoder(for variant: String) -> WhisperKitDecoder {
        watchMemoryPressure()
        evictions.removeValue(forKey: variant)?.cancel()
        if let d = decoders[variant] { return d }
        let d = WhisperKitDecoder(variant: variant)
        decoders[variant] = d
        return d
    }

    /// A lane started using the variant: it stays loaded until every user has released it.
    public func retain(_ variant: String) {
        evictions.removeValue(forKey: variant)?.cancel()
        users[variant, default: 0] += 1
    }

    /// A lane finished with the variant. The last release starts the grace timer.
    public func release(_ variant: String) {
        let remaining = max(0, (users[variant] ?? 0) - 1)
        users[variant] = remaining
        guard remaining == 0 else { return }
        evictions[variant]?.cancel()
        evictions[variant] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleGrace)
            guard !Task.isCancelled else { return }
            await self?.evictIfIdle(variant)
        }
    }

    public func evict(_ variant: String) async {
        evictions.removeValue(forKey: variant)?.cancel()
        if let d = decoders.removeValue(forKey: variant) { await d.unload() }
    }

    private func evictIfIdle(_ variant: String) async {
        guard (users[variant] ?? 0) == 0 else { return }
        evictions.removeValue(forKey: variant)
        if let d = decoders.removeValue(forKey: variant) { await d.unload() }
    }

    /// Under memory pressure every idle model goes now; a model in use is left alone.
    private func evictIdle() async {
        for variant in Array(decoders.keys) where (users[variant] ?? 0) == 0 {
            await evictIfIdle(variant)
        }
    }

    private func watchMemoryPressure() {
        guard pressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.evictIdle() }
        }
        source.activate()
        pressure = source
    }
}
