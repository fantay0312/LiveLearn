import Testing
import Foundation
@testable import EngineKit
import AudioDomain
import CaptionDomain
import ProviderAdapters

/// A recognizer that turns every pushed packet into one volatile chunk and, when told, a final.
final class ScriptedRecognizer: SpeechRecognizer, @unchecked Sendable {
    let lock = NSLock()
    var cont: AsyncStream<RecognizerEvent>.Continuation?
    var blocked: String?
    var autoDetect = false
    var started = 0
    var finished = 0
    var cancelled = 0
    var pushed = 0
    var vocabulary: [String] = []

    var descriptor: EngineStageDescriptor { EngineStageDescriptor(id: "test.recognizer", displayName: "Test ASR", modelID: "t", isLocal: true, dataDestination: "本机处理，不联网", costUnit: "免费") }
    var supportsAutoDetect: Bool { autoDetect }

    func availability(sourceLanguage: String?) async -> StageAvailability { blocked.map { .blocked($0) } ?? .ready }

    func start(_ request: RecognizerRequest) async throws -> RecognizerStream {
        lock.withLock { started += 1; vocabulary = request.vocabulary }
        let (stream, c) = AsyncStream<RecognizerEvent>.makeStream()
        lock.withLock { cont = c }
        return RecognizerStream(inputFormat: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1), events: stream)
    }

    func push(_ packet: ProviderAudioPacket) async {
        let n = lock.withLock { pushed += 1; return pushed }
        lock.withLock { cont }?.yield(.chunk(TranscriptChunk(startNs: 0, endNs: Int64(n) * 100_000_000, text: "hello number \(n)", isFinal: false)))
    }

    func emitFinal(_ text: String, endNs: Int64) {
        lock.withLock { cont }?.yield(.chunk(TranscriptChunk(startNs: 0, endNs: endNs, text: text, isFinal: true)))
    }

    func fail(_ error: ProviderError) {
        lock.withLock { cont }?.yield(.failed(error))
    }

    func finalizePending() async {}
    func finish() async throws {
        lock.withLock { finished += 1 }
        lock.withLock { cont }?.finish()
    }
    func cancel() async {
        lock.withLock { cancelled += 1 }
        lock.withLock { cont }?.finish()
    }
}

final class UppercasingTranslator: TextTranslator, @unchecked Sendable {
    let lock = NSLock()
    var prepared = 0
    var calls: [String] = []
    var failWith: ProviderError?
    var local = true

    var descriptor: EngineStageDescriptor { EngineStageDescriptor(id: "test.translator", displayName: "Test MT", modelID: "t", isLocal: local, dataDestination: local ? "本机处理，不联网" : "文本发送到 Test", costUnit: local ? "免费" : "按 token 计费") }
    func availability(source: String?, target: String) async -> StageAvailability { .ready }
    func prepare(source: String?, target: String) async throws { lock.withLock { prepared += 1 } }
    func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String {
        lock.withLock { calls.append(text) }
        if let failWith { throw failWith }
        return text.uppercased()
    }
    func cancel() {}
}

private func packet(_ n: Int) -> ProviderAudioPacket {
    ProviderAudioPacket(sequence: UInt64(n), captureEpoch: 1, sourceStartNs: Int64(n) * 100_000_000, sourceEndNs: Int64(n + 1) * 100_000_000, format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1), mono: Array(repeating: 0.1, count: 1600), discontinuityBefore: false, rms: 0.1)
}

/// The single consumer of a provider's event stream; tests poll it with a deadline.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProviderEvent] = []
    private var task: Task<Void, Never>?

    init(_ provider: PipelineProvider) {
        task = Task { [weak self] in
            for await e in provider.events {
                guard let self else { return }
                self.lock.withLock { self.events.append(e) }
            }
        }
    }

    deinit { task?.cancel() }

    func wait(until predicate: ([ProviderEvent]) -> Bool, timeoutMs: Int = 2_000) async -> [ProviderEvent] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            let snapshot = lock.withLock { events }
            if predicate(snapshot) { return snapshot }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return lock.withLock { events }
    }
}

private func captions(_ events: [ProviderEvent]) -> [CaptionEvent] {
    events.compactMap { if case .caption(let c) = $0 { return c } else { return nil } }
}

@Suite("Pipeline provider")
struct PipelineProviderTests {
    @Test("Candidates are metadata; the caption and translation keep the recognizer's words", arguments: ["Open live lawn.", "用飞鼠开会。", "用飞鼠打开 live lawn。"])
    func mishearingNeverSilentlyRewrites(text: String) async throws {
        let asr = ScriptedRecognizer()
        let mt = UppercasingTranslator()
        let provider = PipelineProvider(recognizer: asr, translator: mt, providerID: "test", displayName: "Test",
                                        translatesPartials: false, vocabulary: ["LiveLearn", "飞书"])
        let sink = EventSink(provider)
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1,
            sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        asr.emitFinal(text, endNs: 1_000_000_000)
        let events = await sink.wait { captions($0).contains { $0.type == .translationFinal } }
        let final = try #require(captions(events).first { $0.type == .sourceFinal })
        #expect(final.text == text)
        #expect(final.vocabularyCandidates?.isEmpty == false)
        #expect(mt.calls == [text])
        #expect(!captions(events).contains { $0.type == .sourceCorrection })
        var reducer = CaptionReducer(sessionID: "s")
        for event in captions(events) { _ = reducer.apply(event) }
        let segment = try #require(reducer.snapshot.segments.first)
        let candidate = try #require(segment.vocabularyCandidates?.first)
        let reviewResult0 = reducer.reviewVocabularyCandidate(segmentID: segment.id, revision: segment.sourceRevision, candidate: candidate, confirm: true)
        #expect(reviewResult0)
        #expect(reducer.snapshot.segments.first?.history == [text])
        #expect(reducer.snapshot.segments.first?.translation?.isStale == true)
        #expect(mt.calls == [text], "Confirmation does not trigger an undisclosed translation request")
        await provider.cancel()
    }

    @Test("Every recognizer receives vocabulary and calibrated text reaches both captions and translation")
    func vocabularyFlowsThroughBothStages() async throws {
        let asr = ScriptedRecognizer()
        let mt = UppercasingTranslator()
        let provider = PipelineProvider(recognizer: asr, translator: mt, providerID: "test", displayName: "Test", translatesPartials: false,
                                        vocabulary: ["WhisperKit", "SwiftUI"])
        let sink = EventSink(provider)
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        #expect(asr.vocabulary == ["WhisperKit", "SwiftUI"])
        asr.emitFinal("We use whisper kit with swift ui.", endNs: 1_000_000_000)
        let events = await sink.wait { captions($0).contains { $0.type == .translationFinal } }
        #expect(captions(events).first { $0.type == .sourceFinal }?.text == "We use WhisperKit with SwiftUI.")
        #expect(mt.calls == ["We use WhisperKit with SwiftUI."])
        await provider.cancel()
    }

    @Test("Recognizer chunks become source events; finals are translated; the pair reports local")
    func endToEnd() async throws {
        let asr = ScriptedRecognizer()
        let mt = UppercasingTranslator()
        let provider = PipelineProvider(recognizer: asr, translator: mt, providerID: "test", displayName: "Test", translatesPartials: false)
        let sink = EventSink(provider)
        #expect(provider.capabilities.isLocal)
        #expect(provider.capabilities.dataDestination == "本机处理，不联网")
        #expect(provider.capabilities.sourceAutoDetect == .unsupported)
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        #expect(provider.capabilities.inputFormats.first?.sampleRate == 16_000)
        try await provider.push(packet(1))
        try await provider.push(packet(2))
        asr.emitFinal("hello number two", endNs: 300_000_000)
        let events = await sink.wait { captions($0).contains { $0.type == .translationFinal } }
        let caps = captions(events)
        #expect(events.contains { if case .opened(1) = $0 { return true } else { return false } })
        #expect(caps.filter { $0.type == .sourceReplace }.count == 2)
        let final = try #require(caps.first { $0.type == .sourceFinal })
        #expect(final.text == "hello number two")
        #expect(final.revision == 3)
        let translation = try #require(caps.first { $0.type == .translationFinal })
        #expect(translation.text == "HELLO NUMBER TWO")
        #expect(translation.sourceRefs?.first?.segmentID == final.segmentID)
        #expect(mt.calls == ["hello number two"], "partials are not translated when the pipeline says so")
        try await provider.finishInput()
        let closed = await sink.wait { $0.contains { if case .closed = $0 { return true } else { return false } } }
        #expect(closed.contains { if case .closed(1) = $0 { return true } else { return false } })
        #expect(asr.finished == 1)
        #expect(mt.prepared == 1)
    }

    @Test("Partials are translated too when asked, and a cloud translator makes the pair remote")
    func partialsAndRemote() async throws {
        let asr = ScriptedRecognizer()
        let mt = UppercasingTranslator()
        mt.local = false
        let provider = PipelineProvider(recognizer: asr, translator: mt, providerID: "test", displayName: "Test", translatesPartials: true, partialIntervalNs: 1)
        let sink = EventSink(provider)
        #expect(!provider.capabilities.isLocal)
        #expect(provider.capabilities.dataDestination == "识别在本机；文本 → Test MT")
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        try await provider.push(packet(1))
        let events = await sink.wait { captions($0).contains { $0.type == .translationReplace } }
        let tr = try #require(captions(events).first { $0.type == .translationReplace })
        #expect(tr.text == "HELLO NUMBER 1")
        #expect(tr.isFinal == false)
        await provider.cancel()
    }

    @Test("A blocked stage refuses to open with a user-fixable error; auto-detect needs support")
    func gates() async throws {
        let asr = ScriptedRecognizer()
        asr.blocked = "缺少模型"
        let provider = PipelineProvider(recognizer: asr, translator: UppercasingTranslator(), providerID: "test", displayName: "Test")
        await #expect(throws: ProviderError.self) {
            try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        }
        asr.blocked = nil
        await #expect(throws: ProviderError.self) {
            try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: nil, targetLanguage: "zh-Hans", sourceKind: .system))
        }
        asr.autoDetect = true
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: nil, targetLanguage: "zh-Hans", sourceKind: .system))
        #expect(provider.capabilities.sourceAutoDetect == .supported)
        await provider.cancel()
    }

    @Test("Stage failures reach the lane: a retryable recognizer drop and a permanent translator error")
    func failures() async throws {
        let asr = ScriptedRecognizer()
        let mt = UppercasingTranslator()
        mt.failWith = ProviderError(.userFixable, "密钥无效")
        let provider = PipelineProvider(recognizer: asr, translator: mt, providerID: "test", displayName: "Test", translatesPartials: false)
        let sink = EventSink(provider)
        try await provider.open(ProviderSessionConfiguration(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", sourceKind: .system))
        asr.emitFinal("hello", endNs: 100_000_000)
        let events = await sink.wait { $0.contains { if case .disconnected = $0 { return true } else { return false } } }
        let disconnect = try #require(events.compactMap { ev -> ProviderError? in if case .disconnected(_, let e) = ev { return e } else { return nil } }.first)
        #expect(disconnect.classification == .userFixable)
        #expect(disconnect.message.contains("密钥无效"))
        asr.fail(ProviderError(.retryable, "socket closed"))
        let more = await sink.wait { $0.contains { if case .disconnected(_, let e) = $0 { return e.classification == .retryable } else { return false } } }
        #expect(more.contains { if case .disconnected(_, let e) = $0 { return e.message == "socket closed" } else { return false } })
        await provider.cancel()
    }
}
