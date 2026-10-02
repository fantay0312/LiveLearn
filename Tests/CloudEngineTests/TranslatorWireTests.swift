import Testing
import Foundation
@testable import CloudEngine
@testable import EngineKit
import ProviderAdapters

@Suite("OpenAI-compatible translator wire format")
struct OpenAICompatibleWireTests {
    @Test("The request is a chat completion with the bearer token and vendor extras")
    func request() throws {
        let cfg = OpenAICompatibleConfig(vendorID: "deepseek", displayName: "DeepSeek", baseURL: URL(string: "https://api.deepseek.com/v1")!, model: "deepseek-chat", apiKey: "sk-test", isLocal: false, destination: "DeepSeek（中国）", extraBody: ["enable_thinking": "false"])
        let req = try OpenAICompatibleTranslator.request(config: cfg, system: "SYS", text: "Hello")
        #expect(req.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == false)
        #expect(body["enable_thinking"] as? Bool == false)
        let messages = body["messages"] as! [[String: String]]
        #expect(messages[0]["role"] == "system" && messages[0]["content"] == "SYS")
        #expect(messages[1]["role"] == "user" && messages[1]["content"] == "Hello")
    }

    @Test("A local server gets a placeholder token and no key requirement")
    func localServer() async throws {
        let cfg = OpenAICompatibleConfig(vendorID: "ollama", displayName: "Ollama", baseURL: URL(string: "http://localhost:11434/v1/")!, model: "qwen3:8b", apiKey: nil, isLocal: true, destination: "本机")
        let req = try OpenAICompatibleTranslator.request(config: cfg, system: "S", text: "T")
        #expect(req.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer local")
        let t = OpenAICompatibleTranslator(config: cfg, transport: MockTransport { _ in fatalError("not called") })
        #expect(await t.availability(source: "en", target: "zh-Hans") == .ready)
        let cloud = OpenAICompatibleConfig(vendorID: "openai", displayName: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o-mini", apiKey: "", isLocal: false, destination: "OpenAI")
        let blocked = await OpenAICompatibleTranslator(config: cloud, transport: MockTransport { _ in fatalError() }).availability(source: "en", target: "zh-Hans")
        #expect(blocked.blocker?.contains("API Key") == true)
    }

    @Test("The reply's content is the translation, minus thinking blocks and quotes")
    func parse() throws {
        let reply = #"{"choices":[{"message":{"role":"assistant","content":"<think>ok</think>\n“请先不要重启服务器。”"}}]}"#
        #expect(try OpenAICompatibleTranslator.parse(Data(reply.utf8), service: "X") == "请先不要重启服务器。")
        let parts = #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Hola"}]}}]}"#
        #expect(try OpenAICompatibleTranslator.parse(Data(parts.utf8), service: "X") == "Hola")
        let error = #"{"error":{"message":"model not found","type":"invalid_request_error"}}"#
        #expect(throws: ProviderError.self) { try OpenAICompatibleTranslator.parse(Data(error.utf8), service: "X") }
    }

    @Test("HTTP failures map to the lane's error classes")
    func classify() async throws {
        let cfg = OpenAICompatibleConfig(vendorID: "openai", displayName: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o-mini", apiKey: "k", isLocal: false, destination: "OpenAI")
        func run(_ status: Int, _ body: String = "") async -> ProviderError? {
            let t = OpenAICompatibleTranslator(config: cfg, transport: MockTransport { req in
                (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do { _ = try await t.translate("hi", source: "en", target: "zh-Hans", isFinal: true); return nil } catch { return error as? ProviderError }
        }
        #expect(await run(401, #"{"error":{"message":"Incorrect API key"}}"#)?.classification == .userFixable)
        #expect(await run(429)?.classification == .retryable)
        #expect(await run(503)?.classification == .retryable)
        #expect(await run(404)?.classification == .userFixable)
        let ok = OpenAICompatibleTranslator(config: cfg, transport: MockTransport { req in
            (Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await ok.translate("hi", source: "en", target: "zh-Hans", isFinal: true) == "你好")
    }
}

@Suite("Prompt hygiene")
struct PromptTests {
    @Test("The system prompt names both languages and forbids anything but the translation")
    func prompt() {
        let p = TranslationPrompt.system(source: "en", target: "zh-Hans")
        #expect(p.contains("from English into Simplified Chinese"))
        #expect(p.contains("Output only the translation"))
        #expect(p.contains("Simplified Chinese characters"))
        let auto = TranslationPrompt.system(source: nil, target: "ja")
        #expect(auto.contains("Detect the language"))
        #expect(auto.contains("into Japanese"))
    }

    @Test("Cleaning strips think blocks and one pair of quotes, nothing else")
    func clean() {
        #expect(TranslationPrompt.clean("  \"Hello\"  ") == "Hello")
        #expect(TranslationPrompt.clean("<think>reasoning</think>\nHello") == "Hello")
        #expect(TranslationPrompt.clean("He said \"hi\" and \"bye\"") == "He said \"hi\" and \"bye\"")
        #expect(TranslationPrompt.clean("「你好」") == "你好")
    }
}

@Suite("Gemini translator wire format")
struct GeminiWireTests {
    @Test("Request and reply")
    func wire() throws {
        let cfg = GeminiConfig(model: "gemini-2.5-flash", apiKey: "g")
        let req = try GeminiTranslator.request(config: cfg, system: "S", text: "T")
        #expect(req.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "g")
        let reply = #"{"candidates":[{"content":{"parts":[{"text":"thinking","thought":true},{"text":"你好"}],"role":"model"}}]}"#
        #expect(try GeminiTranslator.parse(Data(reply.utf8)) == "你好")
        let blocked = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        #expect(throws: ProviderError.self) { try GeminiTranslator.parse(Data(blocked.utf8)) }
    }
}

/// A transport that answers from a closure and never touches the network.
struct MockTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try handler(request) }
}
