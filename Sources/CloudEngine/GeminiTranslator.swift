import Foundation
import ProviderAdapters
import EngineKit

/// Google Gemini through `generateContent`. One request per sentence.
public struct GeminiConfig: Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var glossary: [GlossaryEntry] = []

    public init(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public final class GeminiTranslator: TextTranslator, @unchecked Sendable {
    public var supportsGlossary: Bool { true }
    public let config: GeminiConfig
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var cancelled = false

    public init(config: GeminiConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "gemini", displayName: "Gemini", modelID: config.model, isLocal: false, dataDestination: "文本发送到 Google Gemini（美国）", costUnit: "按 token 计费")
    }

    public func availability(source: String?, target: String) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("Gemini 需要 API Key；请在 设置 › 引擎 › 翻译 中填写。") }
        if config.model.isEmpty { return .blocked("Gemini 需要一个模型名称。") }
        return .ready
    }

    public func prepare(source: String?, target: String) async throws {
        if case .blocked(let why) = await availability(source: source, target: target) { throw ProviderError(.userFixable, why) }
        lock.withLock { cancelled = false }
    }

    public func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String {
        guard !lock.withLock({ cancelled }) else { return "" }
        let request = try Self.request(config: config, system: TranslationPrompt.system(source: source, target: target, glossary: config.glossary), text: text)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw HTTPFailure.classify(transport: error, service: "Gemini")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure.classify(status: response.statusCode, body: data, service: "Gemini")
        }
        return try Self.parse(data)
    }

    public func cancel() { lock.withLock { cancelled = true } }

    public static func request(config: GeminiConfig, system: String, text: String) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("models/\(config.model):generateContent")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": ["temperature": 0.2],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(.retryable, "Gemini 返回了无法解析的内容")
        }
        if let error = json["error"] as? [String: Any] {
            throw ProviderError(.userFixable, "Gemini：\(error["message"] as? String ?? "错误")")
        }
        guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first,
              let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else {
            if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw ProviderError(.unsupported, "Gemini 拒绝翻译这句（\(reason)）")
            }
            throw ProviderError(.retryable, "Gemini 的回复里没有候选")
        }
        // Thinking models mark their reasoning parts; keep only the answer.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        return TranslationPrompt.clean(text)
    }
}
