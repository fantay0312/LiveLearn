import Foundation
import Testing
@testable import LiveLearnApp

@MainActor
struct DictationFileIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_TEST_AUDIO"] != nil))
    func actualLocalRecognizerStreamsAnAudioFile() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_TEST_AUDIO"])
        let language = ProcessInfo.processInfo.environment["LIVELEARN_DICTATION_TEST_LANGUAGE"] ?? "zh-Hans"
        #expect(await DictationProbe.run(spec: "dictation:\(language):\(file)") == 0)
    }
}
