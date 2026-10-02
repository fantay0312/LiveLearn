import Foundation
import Testing
import AudioDomain
import ProviderAdapters
@testable import EngineKit

private actor TimedTranslator: TextTranslator {
    nonisolated var descriptor: EngineStageDescriptor {
        .init(id: "timed-test", displayName: "Timed test", modelID: "test", isLocal: true, dataDestination: "test", costUnit: "")
    }
    struct Call: Sendable { var text: String; var time: Int64 }
    private(set) var calls: [Call] = []
    let delay: UInt64
    nonisolated let reusesPreviewForFinal: Bool
    init(delay: UInt64 = 0, reuse: Bool = false) { self.delay = delay; self.reusesPreviewForFinal = reuse }
    func availability(source: String?, target: String) async -> StageAvailability { .ready }
    func prepare(source: String?, target: String) async throws {}
    func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String {
        calls.append(Call(text: text, time: MonotonicClock.nowNs()))
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return text
    }
    nonisolated func cancel() {}
}

struct TranslationQueueTests {
    private actor Emissions {
        var requests: [SpeechSegmenter.TranslationRequest] = []
        func append(_ request: SpeechSegmenter.TranslationRequest) { requests.append(request) }
    }

    @Test(arguments: [false, true])
    func identicalFinalReusesOnlyAnExplicitlyCompatiblePreview(reuse: Bool) async throws {
        let translator = TimedTranslator(reuse: reuse)
        let emitted = Emissions()
        let queue = TranslationQueue(translator: translator, source: "en", target: "zh-Hans") { request, _ in await emitted.append(request) }
        await queue.enqueue(request("Same words", final: false))
        try await waitForCalls(1, translator: translator)
        await queue.enqueue(request("Same words", final: true, revision: 4))
        await queue.drain(upToNs: 2_000_000_000)
        #expect(await translator.calls.count == (reuse ? 1 : 2))
        let delivered = await emitted.requests
        #expect(delivered.last?.revision == 4 && delivered.last?.isFinal == true)
        await queue.enqueue(request("Different words", final: true, revision: 5))
        await queue.drain(upToNs: 2_000_000_000)
        #expect(await translator.calls.last?.text == "Different words")
        await queue.cancel()
    }

    private func request(_ text: String, final: Bool, segment: String = "s1", revision: Int = 1) -> SpeechSegmenter.TranslationRequest {
        .init(segmentID: segment, revision: revision, text: text, isFinal: final)
    }

    private func waitForCalls(_ count: Int, translator: TimedTranslator) async throws {
        let end = MonotonicClock.nowNs() + 3_000_000_000
        while await translator.calls.count < count, MonotonicClock.nowNs() < end {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(await translator.calls.count >= count)
    }

    @Test(arguments: [Int64(700_000_000), 1_500_000_000])
    func finalsBypassPreviewThrottle(interval: Int64) async throws {
        let translator = TimedTranslator()
        let queue = TranslationQueue(translator: translator, source: "en", target: "zh-Hans") { _, _ in }
        await queue.setPartialInterval(ns: interval)
        await queue.enqueue(request("preview one", final: false))
        try await waitForCalls(1, translator: translator)
        await queue.enqueue(request("preview two", final: false, revision: 2))
        try await Task.sleep(nanoseconds: 40_000_000)
        let enqueuedAt = MonotonicClock.nowNs()
        await queue.enqueue(request("final one", final: true, revision: 3))
        await queue.drain(upToNs: 3_000_000_000)
        let call = try #require(await translator.calls.first { $0.text == "final one" })
        let latency = Double(call.time - enqueuedAt) / 1_000_000
        print("Final dispatch latency: interval=\(interval / 1_000_000) ms, wait=\(String(format: "%.2f", latency)) ms")
        #expect(latency < 350)
        #expect(await translator.calls.map(\.text) == ["preview one", "final one"])
        await queue.cancel()
    }

    @Test func finalsStaySerialWithoutCancellingAnInFlightTranslation() async throws {
        let translator = TimedTranslator(delay: 80_000_000)
        let queue = TranslationQueue(translator: translator, source: "en", target: "zh-Hans") { _, _ in }
        await queue.enqueue(request("partial", final: false))
        try await waitForCalls(1, translator: translator)
        await queue.enqueue(request("final one", final: true))
        await queue.enqueue(request("final two", final: true, segment: "s2"))
        await queue.drain(upToNs: 2_000_000_000)
        let calls = await translator.calls
        #expect(calls.map(\.text) == ["partial", "final one", "final two"])
        for pair in zip(calls, calls.dropFirst()) { #expect(pair.1.time - pair.0.time >= 70_000_000) }
        await queue.cancel()
    }

    @Test func previewsRemainRateLimitedAndCancellationClearsTheTimer() async throws {
        let translator = TimedTranslator()
        let queue = TranslationQueue(translator: translator, source: "en", target: "zh-Hans") { _, _ in }
        await queue.setPartialInterval(ns: 150_000_000)
        await queue.enqueue(request("first", final: false))
        try await waitForCalls(1, translator: translator)
        await queue.enqueue(request("second", final: false, revision: 2))
        try await waitForCalls(2, translator: translator)
        let calls = await translator.calls
        #expect(calls[1].time - calls[0].time >= 140_000_000)
        await queue.enqueue(request("cancelled", final: false, revision: 3))
        await queue.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await translator.calls.count == 2)
    }
}
