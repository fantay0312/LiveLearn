import Testing
import EngineKit
@testable import LocalEngine

@Suite("Apple vocabulary result boundary")
struct AppleVocabularyCandidateTests {
    @Test(arguments: ["Open live lawn.", "用飞鼠开会。"])
    func resultKeepsMisheardText(text: String) throws {
        guard #available(macOS 26, *) else { return }
        for final in [false, true] {
            let chunk = AppleSpeechState.transcriptChunk(startNs: 100, endNs: 200, text: text, isFinal: final)
            #expect(chunk.text == text && chunk.isFinal == final)
            #expect(chunk.startNs == 100 && chunk.endNs == 200)
            let candidates = VocabularyCandidateGenerator(vocabulary: ["LiveLearn", "飞书"]).candidates(in: chunk.text)
            #expect(!candidates.isEmpty)
            #expect(chunk.text == text)
        }
    }
}
