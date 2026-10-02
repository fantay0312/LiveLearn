import Foundation
import AVFoundation
import CoreMedia
import Speech
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import EngineKit

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "apple-speech")

/// Apple `SpeechAnalyzer` (macOS 26) as a pipeline stage. Nothing leaves the machine.
///
/// Timing: the recognizer is fed a sample-exact timeline anchored to the packets' session time,
/// so result ranges land on the caption axis directly. Consecutive packets continue the sample
/// counter; a discontinuity (pause, device change, clock correction) re-anchors forward, never
/// backwards, because the analyzer refuses audio whose timestamp precedes what it already has.
@available(macOS 26, *)
public final class AppleSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let stageID = "apple.speech"

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: Self.stageID, displayName: "Apple 本机识别", modelID: "apple/SpeechAnalyzer", isLocal: true, dataDestination: "本机处理，不联网", costUnit: "免费")
    }

    private let state = AppleSpeechState()

    public init() {}

    public func availability(sourceLanguage: String?) async -> StageAvailability {
        guard let code = sourceLanguage else { return .blocked("Apple 本机识别不会检测语言；请指定源语言，或改用会检测语言的识别引擎。") }
        let status = LocalPairStatus(source: code, target: code, speech: await LocalEngineAvailability.speechState(language: code), translation: .installed)
        return status.blocker.map { .blocked($0) } ?? .ready
    }

    public func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        guard let source = request.sourceLanguage else {
            throw ProviderError(.unsupported, "Apple 本机识别需要指定源语言，不支持自动检测")
        }
        return try await state.start(sourceLanguage: source, laneID: request.laneID)
    }

    public func push(_ packet: ProviderAudioPacket) async { await state.push(packet) }
    public func finalizePending() async { await state.finalizePending() }
    public func finish() async throws { await state.finish() }
    public func cancel() async { await state.cancel() }
}

/// The analyzer, its input stream and the sample clock, confined to one actor.
@available(macOS 26, *)
actor AppleSpeechState {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var sampleRate: Int64 = 16_000
    private var nextSample: Int64?
    private var events: AsyncStream<RecognizerEvent>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var closed = false
    private var laneID = ""

    func start(sourceLanguage: String, laneID: String) async throws -> RecognizerStream {
        await teardown()
        self.laneID = laneID
        closed = false
        guard let locale = LocalLanguage.speechLocale(for: sourceLanguage) else {
            throw ProviderError(.unsupported, "Apple 本机识别不支持 \(LanguageCatalog.name(sourceLanguage))")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ProviderError(.userFixable, "\(LanguageCatalog.name(sourceLanguage))识别模型尚未就绪；请在 设置 › 本地模型 中下载")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
        } catch {
            throw ProviderError(.retryable, "本机识别启动失败：\(error.localizedDescription)")
        }
        let (out, outCont) = AsyncStream<RecognizerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.input = cont
        self.format = format
        self.sampleRate = Int64(format.sampleRate)
        self.nextSample = nil
        self.events = outCont
        resultsTask = Task { [weak self] in
            await self?.consumeResults(transcriber)
        }
        log.notice("apple speech open lane=\(laneID, privacy: .public) \(sourceLanguage, privacy: .public) format=\(format.sampleRate, privacy: .public) Hz")
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)), events: out)
    }

    private func consumeResults(_ transcriber: SpeechTranscriber) async {
        do {
            for try await result in transcriber.results {
                if Task.isCancelled { return }
                events?.yield(.chunk(Self.transcriptChunk(
                    startNs: Self.ns(result.range.start),
                    endNs: Self.ns(result.range.end),
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                )))
            }
        } catch {
            guard !closed, !Task.isCancelled else { return }
            log.error("apple speech failed: \(error.localizedDescription, privacy: .public)")
            events?.yield(.failed(ProviderError(.retryable, "本机识别中断：\(error.localizedDescription)")))
        }
        events?.finish()
    }

    private static func ns(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return time.convertScale(1_000_000_000, method: .roundHalfAwayFromZero).value
    }

    /// Value boundary shared by SpeechTranscriber results and adapter regressions.
    nonisolated static func transcriptChunk(startNs: Int64, endNs: Int64, text: String, isFinal: Bool) -> TranscriptChunk {
        TranscriptChunk(startNs: startNs, endNs: endNs, text: text, isFinal: isFinal)
    }

    func push(_ packet: ProviderAudioPacket) {
        guard !closed, let input, let format else { return }
        let frames = packet.mono.count
        guard frames > 0 else { return }
        let rate = sampleRate
        let packetStart = Int64((Double(packet.sourceStartNs) * Double(rate) / 1_000_000_000).rounded())
        let base: Int64
        if let next = nextSample, abs(packetStart - next) <= rate / 4 {
            // Within a quarter second of where the sample counter expects it: contiguous audio.
            // Small timeline steps (clock jitter, a short capture stall the lane already reported
            // as a gap) must not become holes here; every hole makes the recognizer end an
            // utterance, and a stream of micro-holes turns speech into one-word fragments.
            base = next
        } else {
            // A real break (pause, long stall, new device): re-anchor forward only, because the
            // analyzer rejects audio that precedes what it already has.
            base = max(packetStart, nextSample ?? 0)
        }
        nextSample = base + Int64(frames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        switch format.commonFormat {
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return }
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<frames {
                    let v = max(-1, min(1, packet.mono[i]))
                    p[i] = Int16((v * 32767).rounded())
                }
            }
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return }
            for c in 0..<channels {
                packet.mono.withUnsafeBufferPointer { src in
                    data[c].update(from: src.baseAddress!, count: frames)
                }
            }
        default:
            return
        }
        input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: base, timescale: CMTimeScale(rate))))
    }

    /// Pause: finalize what has been heard so far without ending the session.
    func finalizePending() async {
        guard !closed, let analyzer else { return }
        try? await analyzer.finalize(through: nil)
    }

    /// Flush: end input, finalize (bounded), let the results task finish the stream.
    func finish() async {
        guard !closed else { return }
        input?.finish()
        input = nil
        if let analyzer {
            let finalized = await Self.withTimeout(ns: 2_000_000_000) {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    log.error("finalize failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if !finalized {
                log.error("finalize timed out; cancelling analysis")
                await analyzer.cancelAndFinishNow()
            }
        }
        await Self.wait(for: resultsTask, upToNs: 1_000_000_000)
        closed = true
        events?.finish()
    }

    func cancel() async {
        closed = true
        await teardown()
    }

    private func teardown() async {
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { await analyzer.cancelAndFinishNow() }
        analyzer = nil
        transcriber = nil
        events?.finish()
        events = nil
    }

    private static func withTimeout(ns: UInt64, _ body: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await body(); return true }
            group.addTask { try? await Task.sleep(nanoseconds: ns); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
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
