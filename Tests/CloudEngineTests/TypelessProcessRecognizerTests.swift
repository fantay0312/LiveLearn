import Foundation
import Testing
import EngineKit
import AudioDomain
@testable import CloudEngine

struct TypelessProcessRecognizerTests {
    private func fixture(mode: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("livelearn-dictation-\(UUID()).sh")
        let source = """
        #!/bin/sh
        IFS= read -r first || exit 1
        printf '%s\\n' '{"type":"ready","mode":"\(mode)"}'
        printf '%s\\n' '{"type":"correction","snapshot":"用 swift ui","segment_final":false}'
        while IFS= read -r line; do
          case "$line" in
            *'"finish"'*) printf '%s\\n' '{"type":"final","text":"用 SwiftUI。","asr_finished":true}'; exit 0 ;;
          esac
        done
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    private func config(_ file: URL) -> TypelessProcessConfig {
        .init(executable: file, url: "wss://fixture.invalid/asr", appKey: "fixture", token: "fixture", deviceID: "1", appID: "1")
    }

    @Test func privatePipeDeliversRevisionsAndExactlyOneFinal() async throws {
        guard #available(macOS 26, *) else { return }
        let file = try fixture(mode: "live")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = TypelessProcessRecognizer(config: config(file))
        let stream = try await engine.start(.init(sessionID: "test", laneID: "dictation", providerEpoch: 1, sourceLanguage: nil, sourceKind: .microphone))
        let collect = Task { () -> [TranscriptChunk] in
            var chunks: [TranscriptChunk] = []
            for await event in stream.events { if case .chunk(let chunk) = event { chunks.append(chunk) } }
            return chunks
        }
        try await engine.finish()
        let chunks = await collect.value
        #expect(chunks.map(\.text) == ["用 swift ui", "用 SwiftUI。"])
        #expect(chunks.filter(\.isFinal).count == 1)
        await engine.cancel()
    }

    @Test func productionAdapterRejectsMockReadiness() async throws {
        guard #available(macOS 26, *) else { return }
        let file = try fixture(mode: "mock")
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = TypelessProcessRecognizer(config: config(file))
        await #expect(throws: (any Error).self) {
            try await engine.start(.init(sessionID: "test", laneID: "dictation", providerEpoch: 1, sourceLanguage: nil, sourceKind: .microphone))
        }
        await engine.cancel()
    }
}
