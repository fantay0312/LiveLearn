import Foundation
import Testing
@testable import CloudEngine
import ProviderAdapters

private actor DictationHTTP: HTTPTransport {
    var request: URLRequest?
    var output: String
    init(_ output: String) { self.output = output }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": output]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct DictationCorrectorTests {
    private var config: OpenAICompatibleConfig {
        .init(vendorID: "local", displayName: "Test", baseURL: URL(string: "http://localhost:1234/v1")!, model: "test",
              apiKey: nil, isLocal: true, destination: "本机")
    }

    @Test func usesDictationPromptAndKeepsMixedLanguage() async throws {
        let transport = DictationHTTP("{\"text\":\"用 SwiftUI 调用 API，版本 2.0。\"}")
        let corrector = DictationCorrector(config: config, transport: transport)
        let output = try await corrector.correct("用 swift ui 调用API版本2.0", vocabulary: ["SwiftUI"])
        #expect(output == "用 SwiftUI 调用 API，版本 2.0。")
        let request = try #require(await transport.request)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages[0]["content"]?.contains("Do not rewrite") == true)
        #expect(messages[1]["content"] == "用 swift ui 调用API版本2.0")
    }

    @Test func rejectsMissingAndEmptyCorrection() async {
        for reply in ["Sure! Here is your result", "{\"text\":\"\"}", "{}"] {
            await #expect(throws: (any Error).self) {
                try await DictationCorrector(config: config, transport: DictationHTTP(reply)).correct("原文", vocabulary: [])
            }
        }
    }

    @Test func doubaoTwoPassIsOptInAndDoesNotForceSingleLanguage() throws {
        var config = DoubaoConfig(appKey: nil, accessKey: "test")
        config.enableNonstream = true
        let body = try #require(JSONSerialization.jsonObject(with: DoubaoRecognizer.fullClientRequest(config: config)) as? [String: Any])
        #expect((body["request"] as? [String: Any])?["enable_nonstream"] as? Bool == true)
        #expect((body["audio"] as? [String: Any])?["language"] == nil)
    }

    @Test func correctionCannotChangeNumbersOrRemoveCorrectTerms() {
        #expect(!DictationCorrector.preservesProtectedContent(original: "API v2.0", proposal: "API v3.0", vocabulary: ["API"]))
        #expect(!DictationCorrector.preservesProtectedContent(original: "请用 SwiftUI", proposal: "请用界面框架", vocabulary: ["SwiftUI"]))
        #expect(DictationCorrector.preservesProtectedContent(original: "用配森读取杰森", proposal: "用 Python 读取 JSON", vocabulary: ["Python", "JSON"]))
    }
}
