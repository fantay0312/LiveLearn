import Foundation
import ProviderAdapters
import EngineKit

/// Anthropic Messages API (`POST /v1/messages`). One request per sentence, no streaming: a
/// translation is short and the caption shows it whole.
public struct AnthropicConfig: Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String?
    public var glossary: [GlossaryEntry] = []
    public static let apiVersion = "2023-06-01"

    public init(baseURL: URL = URL(string: "https://api.anthropic.com")!, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public final class AnthropicTranslator: TextTranslator, @unchecked Sendable {
    public var supportsGlossary: Bool { true }
    public let config: AnthropicConfig
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var cancelled = false

    public init(config: AnthropicConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(id: "anthropic", displayName: "Claude", modelID: config.model, isLocal: false, dataDestination: "文本发送到 Anthropic Claude（美国）", costUnit: "按 token 计费")
    }

    public func availability(source: String?, target: String) async -> StageAvailability {
        if (config.apiKey ?? "").isEmpty { return .blocked("Claude 需要 API Key；请在 设置 › 引擎 › 翻译 中填写。") }
        if config.model.isEmpty { return .blocked("Claude 需要一个模型名称。") }
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
            throw HTTPFailure.classify(transport: error, service: "Claude")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure.classify(status: response.statusCode, body: data, service: "Claude")
        }
        return try Self.parse(data)
    }

    public func cancel() { lock.withLock { cancelled = true } }

    public static func request(config: AnthropicConfig, system: String, text: String) throws -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey ?? "", forHTTPHeaderField: "x-api-key")
        req.setValue(AnthropicConfig.apiVersion, forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "system": system,
            "messages": [["role": "user", "content": text]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(.retryable, "Claude 返回了无法解析的内容")
        }
        if let error = json["error"] as? [String: Any] {
            throw ProviderError(.userFixable, "Claude：\(error["message"] as? String ?? "错误")")
        }
        // A safety decline arrives as HTTP 200 with its own stop reason; the sentence stays
        // untranslated rather than the lane failing.
        if json["stop_reason"] as? String == "refusal" { return "" }
        guard let content = json["content"] as? [[String: Any]] else {
            throw ProviderError(.retryable, "Claude 的回复里没有 content")
        }
        let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return TranslationPrompt.clean(text)
    }
}
