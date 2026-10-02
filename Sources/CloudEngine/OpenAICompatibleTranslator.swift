import Foundation
import ProviderAdapters
import EngineKit

/// Everything that speaks `POST /chat/completions`: OpenAI, DeepSeek, Qwen (DashScope
/// compatible mode), Moonshot, Groq, OpenRouter, and the local servers (Ollama, LM Studio,
/// llama.cpp, MLX). One request per sentence, no streaming: a translation is short and the
/// caption shows it whole.
public struct OpenAICompatibleConfig: Sendable, Equatable {
    /// Vendor preset id ("openai", "deepseek", "ollama", "custom"…), for the key store and copy.
    public var vendorID: String
    public var displayName: String
    /// The `/v1` root, e.g. `https://api.deepseek.com/v1` or `http://localhost:11434/v1`.
    public var baseURL: URL
    public var model: String
    /// Nil for local servers that need none; sent as a bearer token otherwise.
    public var apiKey: String?
    /// The server runs on this machine (localhost): no data leaves it.
    public var isLocal: Bool
    /// The vendor refuses requests without a key; self-hosted servers usually do not.
    public var requiresKey: Bool
    /// Where the text goes, for the settings screen ("DeepSeek（中国）").
    public var destination: String
    /// Extra body fields a vendor needs (Qwen: `enable_thinking: false`; Ollama: `reasoning_effort: "none"`).
    public var extraBody: [String: String]
    public var temperature: Double
    /// Fixed translations from the 词汇 page, quoted into the system prompt.
    public var glossary: [GlossaryEntry] = []

    public init(vendorID: String, displayName: String, baseURL: URL, model: String, apiKey: String?, isLocal: Bool, requiresKey: Bool? = nil, destination: String, extraBody: [String: String] = [:], temperature: Double = 0.2) {
        self.vendorID = vendorID
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.isLocal = isLocal
        self.requiresKey = requiresKey ?? !isLocal
        self.destination = destination
        self.extraBody = extraBody
        self.temperature = temperature
    }
}

public final class OpenAICompatibleTranslator: TextTranslator, @unchecked Sendable {
    public var supportsGlossary: Bool { true }
    public let config: OpenAICompatibleConfig
    private let transport: any HTTPTransport
    private let lock = NSLock()
    private var cancelled = false

    public init(config: OpenAICompatibleConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public var descriptor: EngineStageDescriptor {
        EngineStageDescriptor(
            id: "openai-compatible.\(config.vendorID)",
            displayName: config.displayName,
            modelID: config.model,
            isLocal: config.isLocal,
            dataDestination: config.isLocal ? "本机服务（\(config.baseURL.host ?? "localhost")），不出本机" : "文本发送到 \(config.destination)",
            costUnit: config.isLocal ? "免费" : "按 token 计费"
        )
    }

    public func availability(source: String?, target: String) async -> StageAvailability {
        if config.requiresKey, (config.apiKey ?? "").isEmpty {
            return .blocked("\(config.displayName) 需要 API Key；请在 设置 › 引擎 › 翻译 中填写。")
        }
        if config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return .blocked("\(config.displayName) 需要一个模型名称；请在 设置 › 引擎 › 翻译 中填写。")
        }
        return .ready
    }

    /// No network here: the first sentence proves the connection, and a failure then is
    /// classified and shown on the lane. Starting a session is the user's explicit go-ahead.
    public func prepare(source: String?, target: String) async throws {
        if case .blocked(let why) = await availability(source: source, target: target) {
            throw ProviderError(.userFixable, why)
        }
        lock.withLock { cancelled = false }
    }

    public func translate(_ text: String, source: String?, target: String, isFinal: Bool) async throws -> String {
        guard !lock.withLock({ cancelled }) else { return "" }
        let request = try Self.request(config: config, system: TranslationPrompt.system(source: source, target: target, glossary: config.glossary), text: text)
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw HTTPFailure.classify(transport: error, service: config.displayName)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPFailure.classify(status: response.statusCode, body: data, service: config.displayName)
        }
        return try Self.parse(data, service: config.displayName)
    }

    public func cancel() {
        lock.withLock { cancelled = true }
    }

    // MARK: - Wire format (pure, tested)

    public static func request(config: OpenAICompatibleConfig, system: String, text: String) throws -> URLRequest {
        var url = config.baseURL
        if url.path.hasSuffix("/") { url = URL(string: String(url.absoluteString.dropLast())) ?? url }
        url = url.appendingPathComponent("chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local servers ignore the token; OpenAI-style client libraries send one anyway, and
        // Ollama documents it as "required but ignored".
        let token = (config.apiKey?.isEmpty == false) ? config.apiKey! : (config.isLocal ? "local" : "")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            "temperature": config.temperature,
            "stream": false,
        ]
        for (k, v) in config.extraBody {
            // Booleans and numbers are passed through as such; a JSON object or array literal
            // (`{"type":"disabled"}`) is embedded as one; everything else is a string.
            if v == "true" {
                body[k] = true
            } else if v == "false" {
                body[k] = false
            } else if let n = Int(v) {
                body[k] = n
            } else if let first = v.first, first == "{" || first == "[", let obj = try? JSONSerialization.jsonObject(with: Data(v.utf8)) {
                body[k] = obj
            } else {
                body[k] = v
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    public static func parse(_ data: Data, service: String) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(.retryable, "\(service) 返回了无法解析的内容")
        }
        if let error = json["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
            throw ProviderError(.userFixable, "\(service)：\(message)")
        }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw ProviderError(.retryable, "\(service) 的回复里没有 choices")
        }
        var content = ""
        if let s = message["content"] as? String {
            content = s
        } else if let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { $0["text"] as? String }.joined()
        }
        return TranslationPrompt.clean(content)
    }
}
