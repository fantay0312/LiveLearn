import Foundation
import Testing
import AudioDomain
@testable import LiveLearnApp

private final class CheckCapture: AudioCapture, @unchecked Sendable {
    let laneID = "check"
    let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    let amplitude: Float?
    let failsPrepare: Bool
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    init(amplitude: Float? = nil, failsPrepare: Bool = false) {
        self.amplitude = amplitude; self.failsPrepare = failsPrepare
        (events, continuation) = AsyncStream.makeStream()
    }
    func prepare(_ source: AudioSourceDescriptor) async throws {
        if failsPrepare { throw CaptureFailure(kind: .permissionDenied, message: "需要录音权限") }
    }
    func start() async throws {
        lock.withLock { starts += 1 }
        let format = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
        continuation.yield(.started(epoch: 1, format: format))
        if let amplitude {
            continuation.yield(.packet(AudioPacket(laneID: laneID, captureEpoch: 1, sequence: 1, sourceStartNs: 0, sourceEndNs: 100_000_000,
                format: format, samples: OwnedAudioBuffer(mono: Array(repeating: amplitude, count: 1600)), discontinuityBefore: false)))
        }
    }
    func stop() async { lock.withLock { stops += 1 }; continuation.finish() }
}

struct SourceCheckTests {
    @Test(arguments: [Float(0), Float(0.1)])
    func silenceAndSoundHaveDistinctReports(_ amplitude: Float) async {
        let capture = CheckCapture(amplitude: amplitude)
        let report = await SourceCheck.run(.system, seconds: 1, capture: capture)
        #expect(report.ok)
        #expect(report.outcome == (amplitude == 0 ? .silent : .audible))
        #expect(capture.stopCount == 1)
        #expect(!report.title.contains("kHz") && !report.summary.contains("Float32"))
    }

    @Test func cancellationStopsCapturePromptly() async throws {
        let capture = CheckCapture()
        let task = Task { await SourceCheck.run(.system, seconds: 30, capture: capture) }
        let deadline = Date().addingTimeInterval(2)
        while capture.startCount == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(capture.startCount == 1)
        let before = Date()
        task.cancel()
        let report = await task.value
        #expect(Date().timeIntervalSince(before) < 1)
        #expect(report.outcome == .cancelled && capture.stopCount == 1)
    }

    @Test func failedPreparationCleansUpAndOffersRecovery() async {
        let capture = CheckCapture(failsPrepare: true)
        let report = await SourceCheck.run(.system, seconds: 1, capture: capture)
        #expect(!report.ok && report.outcome == .failed)
        #expect(report.advice?.action == .openAudioCaptureSettings)
        #expect(capture.startCount == 0 && capture.stopCount == 1)
    }

    @Test func mixedSourcesDoNotClaimAllSourcesHaveSound() {
        let audible = SourceCheck.Report(lines: ["system"], advice: nil, ok: true)
        let silent = SourceCheck.Report(lines: ["mic"], advice: nil, ok: true, outcome: .silent)
        let mixed = SourceCheck.Report.combining([audible, silent])
        #expect(mixed.outcome == .partial && mixed.lines == ["system", "mic"])
        let failed = SourceCheck.Report(lines: [], advice: nil, ok: false)
        #expect(SourceCheck.Report.combining([audible, failed]).outcome == .failed)
    }
}
