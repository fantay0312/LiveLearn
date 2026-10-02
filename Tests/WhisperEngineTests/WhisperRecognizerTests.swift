import Testing
import Foundation
@testable import WhisperEngine
import EngineKit
import AudioDomain
import ProviderAdapters

/// Answers every decode from a script; records what it was asked.
final class ScriptedDecoder: WhisperDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var partialText: String
    private var finalText: String
    private(set) var calls: [(samples: Int, partial: Bool, language: String?)] = []
    private(set) var vocabularies: [[String]] = []
    var loaded = false
    /// How long a decode takes, so a test can have one in flight when the next job arrives.
    var decodeDelayNs: UInt64 = 0
    private var interruptFlag = false
    private(set) var interrupts = 0

    init(partial: String, final: String) {
        partialText = partial
        finalText = final
    }

    func load() async throws { lock.withLock { loaded = true } }
    func decode(_ samples: [Float], language: String?, partial: Bool, vocabulary: [String]) async throws -> WhisperDecodeResult {
        lock.withLock { vocabularies.append(vocabulary) }
        return try await decode(samples, language: language, partial: partial)
    }
    func decode(_ samples: [Float], language: String?, partial: Bool) async throws -> WhisperDecodeResult {
        lock.withLock { calls.append((samples.count, partial, language)); interruptFlag = false }
        if decodeDelayNs > 0 { try? await Task.sleep(nanoseconds: decodeDelayNs) }
        let text = partial ? partialText : finalText
        let seconds = Double(samples.count) / 16_000
        let interrupted = lock.withLock { interruptFlag }
        return WhisperDecodeResult(segments: text.isEmpty ? [] : [WhisperSegment(start: 0, end: seconds, text: text)], interrupted: interrupted)
    }
    func interrupt() { lock.withLock { interruptFlag = true; interrupts += 1 } }
    func unload() async {}

    var callCount: Int { lock.withLock { calls.count } }
    var interruptCount: Int { lock.withLock { interrupts } }
}

actor ChunkBox {
    var chunks: [TranscriptChunk] = []
    var failures: [String] = []
    func take(_ e: RecognizerEvent) {
        switch e {
        case .chunk(let c): chunks.append(c)
        case .failed(let f): failures.append(f.message)
        }
    }
}

private func packet(seq: UInt64, ms: Int, rms: Float, startNs: Int64) -> ProviderAudioPacket {
    ProviderAudioPacket(sequence: seq, captureEpoch: 1, sourceStartNs: startNs, sourceEndNs: startNs + Int64(ms) * 1_000_000, format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1), mono: Array(repeating: rms, count: 16 * ms), discontinuityBefore: false, rms: rms)
}

/// The worker decodes on its own schedule; a test that stops right after the packet which
/// asked for a partial would supersede that partial with the final, which is correct but
/// not what the test wants to observe.
private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@Suite("Whisper recognizer")
struct WhisperRecognizerTests {
    @Test("Whisper decoding preserves user-review candidates in both languages", arguments: ["Open live lawn.", "用飞鼠开会。"])
    func vocabularyMishearingNeedsConfirmation(text: String) async throws {
        let decoder = ScriptedDecoder(partial: text, final: text)
        let recognizer = WhisperKitRecognizer(config: WhisperConfig(variant: "openai_whisper-base"), decoder: decoder)
        let vocabulary = ["LiveLearn", "飞书"]
        let stream = try await recognizer.start(RecognizerRequest(sessionID: "s", laneID: "mic", providerEpoch: 1,
            sourceLanguage: nil, sourceKind: .microphone, vocabulary: vocabulary))
        let box = ChunkBox()
        let reader = Task { for await event in stream.events { await box.take(event) } }
        for n in 0..<15 {
            await recognizer.push(packet(seq: UInt64(n + 1), ms: 100, rms: 0.05, startNs: Int64(n) * 100_000_000))
        }
        await waitUntil { decoder.callCount >= 1 }
        try await recognizer.finish()
        await reader.value
        let chunks = await box.chunks
        let final = try #require(chunks.last { $0.isFinal })
        #expect(final.text == text)
        #expect(chunks.allSatisfy { $0.text == text })
        #expect(decoder.vocabularies.allSatisfy { $0 == vocabulary })
        #expect(VocabularyCandidateGenerator(vocabulary: vocabulary).candidates(in: final.text).count == 1)
    }

    @Test("Speech then silence yields a partial and then a final on the packets' timeline")
    func partialThenFinal() async throws {
        let decoder = ScriptedDecoder(partial: " Please do not", final: " Please do not restart the server yet.")
        let recognizer = WhisperKitRecognizer(config: WhisperConfig(variant: "openai_whisper-base"), decoder: decoder)
        let stream = try await recognizer.start(RecognizerRequest(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", sourceKind: .system, vocabulary: ["WhisperKit", "LiveLearn"]))
        #expect(stream.inputFormat.sampleRate == 16_000)
        let box = ChunkBox()
        let events = stream.events
        let reader = Task { for await e in events { await box.take(e) } }

        var now: Int64 = 1_000_000_000
        var seq: UInt64 = 0
        for _ in 0..<15 {
            seq += 1
            await recognizer.push(packet(seq: seq, ms: 100, rms: 0.05, startNs: now))
            now += 100_000_000
        }
        await waitUntil { decoder.callCount >= 1 }
        for _ in 0..<8 {
            seq += 1
            await recognizer.push(packet(seq: seq, ms: 100, rms: 0, startNs: now))
            now += 100_000_000
        }
        try await recognizer.finish()
        await reader.value

        let chunks = await box.chunks
        #expect(await box.failures.isEmpty)
        #expect(chunks.count == 2)
        #expect(chunks.first?.isFinal == false)
        #expect(chunks.first?.text == "Please do not")
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.last?.text == "Please do not restart the server yet.")
        // No pre-roll silence existed before the first voiced packet, so the clip starts there;
        // 1.5 s of speech plus the 200 ms tail that is kept.
        #expect(chunks.last?.startNs == Int64(1_000_000_000))
        #expect(chunks.last?.endNs == Int64(2_700_000_000))
        #expect(decoder.calls.allSatisfy { $0.language == "en" })
        #expect(decoder.vocabularies.count == decoder.calls.count)
        #expect(decoder.vocabularies.allSatisfy { $0 == ["WhisperKit", "LiveLearn"] })
    }

    @Test("A final that decodes to nothing after a shown partial closes the guess with an empty final")
    func silentFinalClosesPartial() async throws {
        let decoder = ScriptedDecoder(partial: " hello", final: " Thank you.")
        let recognizer = WhisperKitRecognizer(config: WhisperConfig(variant: "openai_whisper-base"), decoder: decoder)
        let stream = try await recognizer.start(RecognizerRequest(sessionID: "s", laneID: "mic", providerEpoch: 1, sourceLanguage: nil, sourceKind: .microphone))
        let box = ChunkBox()
        let events = stream.events
        let reader = Task { for await e in events { await box.take(e) } }
        var now: Int64 = 0
        var seq: UInt64 = 0
        for _ in 0..<12 {
            seq += 1
            await recognizer.push(packet(seq: seq, ms: 100, rms: 0.05, startNs: now))
            now += 100_000_000
        }
        await waitUntil { decoder.callCount >= 1 }
        try await recognizer.finish()
        await reader.value
        let chunks = await box.chunks
        #expect(chunks.count == 2)
        #expect(chunks.first?.text == "hello" && chunks.first?.isFinal == false)
        #expect(chunks.last?.text == "" && chunks.last?.isFinal == true)
        #expect(decoder.calls.allSatisfy { $0.language == nil }, "auto-detect passes no language")
    }

    @Test("A final in flight is never cut by the next sentence's final; both arrive whole")
    func finalsQueue() async throws {
        let decoder = ScriptedDecoder(partial: " partial", final: " whole sentence.")
        decoder.decodeDelayNs = 300_000_000
        let recognizer = WhisperKitRecognizer(config: WhisperConfig(variant: "openai_whisper-base"), decoder: decoder)
        let stream = try await recognizer.start(RecognizerRequest(sessionID: "s", laneID: "remote", providerEpoch: 1, sourceLanguage: "en", sourceKind: .system))
        let box = ChunkBox()
        let events = stream.events
        let reader = Task { for await e in events { await box.take(e) } }
        var now: Int64 = 0
        var seq: UInt64 = 0
        func feed(_ count: Int, _ rms: Float) async {
            for _ in 0..<count {
                seq += 1
                await recognizer.push(packet(seq: seq, ms: 100, rms: rms, startNs: now))
                now += 100_000_000
            }
        }
        // Sentence A: 1.5 s speech (one partial), 600 ms silence closes it. The close cuts the
        // partial decode in flight (the one legitimate interrupt). Once A's final decode is
        // running (300 ms), sentence B (0.5 s speech, too short for a partial) closes behind it.
        await feed(15, 0.05)
        await waitUntil { decoder.callCount >= 1 }
        await feed(6, 0)
        await waitUntil { decoder.callCount >= 2 }
        await feed(5, 0.05)
        await feed(6, 0)
        try await recognizer.finish()
        await reader.value
        let finals = await box.chunks.filter(\.isFinal)
        #expect(finals.count == 2)
        #expect(finals.allSatisfy { $0.text == "whole sentence." })
        #expect(decoder.interruptCount == 1, "only the partial may be interrupted")
    }

    @Test("A missing model blocks with a message that points at the models page")
    func missingModel() async {
        let recognizer = WhisperKitRecognizer(config: WhisperConfig(variant: "openai_whisper-not-a-model"))
        let a = await recognizer.availability(sourceLanguage: "en")
        #expect(a.blocker?.contains("本地模型") == true)
        #expect(recognizer.supportsAutoDetect)
        #expect(recognizer.descriptor.isLocal)
    }
}
