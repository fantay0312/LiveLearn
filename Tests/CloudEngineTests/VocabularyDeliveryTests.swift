import Foundation
import Testing
import EngineKit
@testable import CloudEngine

struct VocabularyDeliveryTests {
    @Test(arguments: ["openai", "ollama", "lmstudio", "anthropic", "gemini"])
    func realTranslatorEntryPointIncludesGlossaryInOutgoingRequest(_ vendor: String) async throws {
        let glossary = [GlossaryEntry(source: "latency", target: "时延")]
        let transport = MockTransport { request in
            let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
            let instruction: String
            let response: String
            if vendor == "anthropic" {
                instruction = body["system"] as? String ?? ""
                response = #"{"content":[{"type":"text","text":"时延"}]}"#
            } else if vendor == "gemini" {
                let parts = (body["systemInstruction"] as? [String: Any])?["parts"] as? [[String: String]]
                instruction = parts?.first?["text"] ?? ""
                response = #"{"candidates":[{"content":{"parts":[{"text":"时延"}]}}]}"#
            } else {
                instruction = (body["messages"] as? [[String: String]])?.first?["content"] ?? ""
                response = #"{"choices":[{"message":{"content":"时延"}}]}"#
            }
            #expect(instruction.contains("latency") && instruction.contains("时延"))
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let translator: any TextTranslator
        switch vendor {
        case "anthropic":
            var config = AnthropicConfig(model: "test", apiKey: nil)
            config.glossary = glossary
            translator = AnthropicTranslator(config: config, transport: transport)
        case "gemini":
            var config = GeminiConfig(model: "test", apiKey: nil)
            config.glossary = glossary
            translator = GeminiTranslator(config: config, transport: transport)
        default:
            var config = OpenAICompatibleConfig(vendorID: vendor, displayName: vendor, baseURL: URL(string: "http://localhost:11434/v1")!, model: "test", apiKey: nil, isLocal: vendor != "openai", destination: "test")
            config.glossary = glossary
            translator = OpenAICompatibleTranslator(config: config, transport: transport)
        }
        #expect(try await translator.translate("latency", source: "en", target: "zh-Hans", isFinal: true) == "时延")
    }
}
