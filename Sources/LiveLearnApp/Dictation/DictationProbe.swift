import Foundation
import AVFoundation
import LocalEngine
import AudioDomain

/// File-based acceptance check using the production controller and an on-device engine.
@MainActor
enum DictationProbe {
    static func run(spec: String) async -> Int32 {
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, #available(macOS 26, *) else { return 2 }
        let url = URL(fileURLWithPath: parts[2])
        do {
            let file = try AVAudioFile(forReading: url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let settings = DictationSettings(defaults: UserDefaults(suiteName: "LiveLearn.testing.dictationProbe")!)
            let controller = DictationController(settings: settings)
            controller.configuration = {
                DictationConfiguration(recognizer: AppleSpeechRecognizer(), language: parts[1], vocabulary: ["SwiftUI", "LiveLearn", "Codex", "API"],
                    replacements: [], corrector: nil, microphoneID: nil, liveInsertion: false)
            }
            controller.captureFactory = { FileCapture(laneID: "dictation", sessionAnchorNs: MonotonicClock.nowNs(), url: url) }
            controller.start(previewOnly: true)
            let startupDeadline = ContinuousClock.now + .seconds(30)
            while controller.phase == .starting, ContinuousClock.now < startupDeadline { try await Task.sleep(for: .milliseconds(20)) }
            guard controller.phase == .listening else {
                throw NSError(domain: "DictationProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: controller.notice ?? "not listening"])
            }
            var previews: [String] = []
            let end = ContinuousClock.now + .seconds(duration + 0.5)
            while ContinuousClock.now < end, controller.phase == .listening {
                if !controller.text.isEmpty, previews.last != controller.text { previews.append(controller.text) }
                try await Task.sleep(for: .milliseconds(50))
            }
            controller.finish()
            let finalDeadline = ContinuousClock.now + .seconds(40)
            while controller.isActive, ContinuousClock.now < finalDeadline { try await Task.sleep(for: .milliseconds(20)) }
            let result: [String: Any] = ["phase": controller.phase.rawValue, "text": controller.text,
                "previews": previews, "notice": controller.notice ?? "", "engine": "Apple on-device", "audioDuration": duration,
                "accessibilityGranted": DictationInputTarget.accessibilityGranted]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url.deletingPathExtension().appendingPathExtension("dictation.json"))
            let passed = controller.phase == .completed && !controller.text.isEmpty
            controller.shutdown()
            print("dictation file probe: \(passed ? "passed" : "failed")")
            return passed ? 0 : 1
        } catch {
            print("dictation file probe failed: \(error.localizedDescription)")
            return 1
        }
    }
}
