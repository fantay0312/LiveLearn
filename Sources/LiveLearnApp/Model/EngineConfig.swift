import Foundation
import CaptionDomain
import ProviderAdapters
import EngineKit
import LocalEngine
import CloudEngine
import WhisperEngine

/// Which recognizer a new session uses. Apple's and Whisper stay on the machine; the others
/// send audio to a service (or to a compatible server the user runs locally).
enum RecognizerChoice: String, CaseIterable, Identifiable {
    case appleSpeech
    case whisperKit
    case doubao
    case paraformer
    case openAIRealtime
    case deepgram
    case soniox
    case geminiLive

    var id: String { rawValue }

    /// The menu row under a group already titled 识别: the name alone (§9.4), the explainers
    /// live in `note`.
    var label: String {
        switch self {
        case .appleSpeech: return "Apple 本机"
        case .whisperKit: return "Whisper 本机"
        case .doubao: return "豆包"
        case .paraformer: return "阿里云 Paraformer"
        case .openAIRealtime: return "OpenAI 实时"
        case .deepgram: return "Deepgram"
        case .soniox: return "Soniox"
        case .geminiLive: return "Gemini 实时"
        }
    }

    var shortLabel: String {
        switch self {
        case .appleSpeech: return "Apple 识别"
        case .whisperKit: return "Whisper 识别"
        case .doubao: return "豆包识别"
        case .paraformer: return "阿里云识别"
        case .openAIRealtime: return "OpenAI 识别"
        case .deepgram: return "Deepgram 识别"
        case .soniox: return "Soniox 识别"
        case .geminiLive: return "Gemini 识别"
        }
    }

    var note: String {
        switch self {
        case .appleSpeech: return "系统自带的 SpeechAnalyzer，模型下载后不联网；需要 macOS 26，语言以「本地模型」页为准。"
        case .whisperKit: return "开源 Whisper 模型在本机 CoreML 上运行，不联网，macOS 15 即可，会自动检测语言。以句为单位识别：一句说完后约 1–2 秒出定稿，说话中每秒刷新一次预览。模型在「本地模型」页下载，中日韩建议 large-v3 压缩版。"
        case .doubao: return "音频以 16 kHz PCM 发送到火山引擎的大模型流式语音识别（bigmodel），按音频小时计费，2.0 资源更便宜，句子带毫秒时间。只支持中文与英文（可混说），没有语言参数。"
        case .paraformer: return "音频发送到阿里云百炼的 Paraformer / Fun-ASR 实时识别，按时长计费；支持中、英、日、粤、韩、德、法、俄，句子带毫秒时间；Key 与通义千问翻译共用。"
        case .openAIRealtime: return "音频以 24 kHz PCM 持续发送到 OpenAI Realtime（intent=transcription），按音频分钟计费，单次会话最长 60 分钟后自动重连。也可填自建的兼容服务地址。"
        case .deepgram: return "音频以 16 kHz PCM 发送到 Deepgram（nova-3），按音频分钟计费。「自动识别」只覆盖十种语言，不含中文与韩语。"
        case .soniox: return "音频发送到 Soniox（stt-rt-v5），按音频小时计费；60 多种语言含中日韩，会自行判断语言，词带毫秒时间，一条流最长 300 分钟。"
        case .geminiLive: return "音频发送到 Gemini Live（gemini-3.5-transcribe-live），按音频 token 计费；SMART 模式自动判断语言；单次连接约 10 分钟后自动重连，重连瞬间的话会丢；没有时间戳，字幕时间按已发送的音频估算。Key 与 Gemini 翻译共用。"
        }
    }

    var isLocal: Bool { self == .appleSpeech || self == .whisperKit }
}

/// Which translator a new session uses.
enum TranslatorChoice: String, CaseIterable, Identifiable {
    case appleTranslation
    case chat
    case anthropic
    case gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleTranslation: return "Apple 本机"
        case .chat: return "OpenAI 兼容接口"
        case .anthropic: return "Anthropic Claude"
        case .gemini: return "Google Gemini"
        }
    }

    var note: String {
        switch self {
        case .appleTranslation: return "系统自带的 Translation 语言包，不联网；需要 macOS 26。源语言选「自动」时，会在本机判断文本语言，仅翻译已安装语言包的方向。"
        case .chat: return "任何提供 /v1/chat/completions 的服务：OpenAI、DeepSeek、通义千问、Kimi、Groq、OpenRouter，或本机的 Ollama、LM Studio、llama.cpp、MLX。每句一次请求，按 token 计费；本机服务免费。"
        case .anthropic: return "Anthropic Messages API，每句一次请求，按 token 计费。"
        case .gemini: return "Google generateContent 接口，每句一次请求，按 token 计费。"
        }
    }
}

/// Presets for the OpenAI-compatible translator: where the `/v1` root is, which model to start
/// with, and whether the server lives on this machine. Every field stays editable. Base URLs
/// and default models were checked against each vendor's docs on 2026-09-07; a model that a
/// vendor retires is edited in the settings, not in code.
enum ChatVendor: String, CaseIterable, Identifiable {
    case openai, deepseek, doubao, qwen, moonshot, zhipu, siliconflow, xfyun, minimax, qianfan
    case groq, openrouter, xai, mistral, together
    case ollama, lmstudio, custom

    var id: String { rawValue }

    /// Menu sections: China first (the user's region), then abroad, then this machine.
    static let groups: [(title: String, vendors: [ChatVendor])] = [
        ("国内服务", [.doubao, .deepseek, .qwen, .moonshot, .zhipu, .siliconflow, .xfyun, .minimax, .qianfan]),
        ("海外服务", [.openai, .groq, .openrouter, .xai, .mistral, .together]),
        ("本机与自定义", [.ollama, .lmstudio, .custom]),
    ]

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .doubao: return "豆包（火山方舟）"
        case .qwen: return "通义千问（阿里云百炼）"
        case .moonshot: return "Kimi（月之暗面）"
        case .zhipu: return "智谱 GLM"
        case .siliconflow: return "硅基流动 SiliconFlow"
        case .xfyun: return "讯飞星火"
        case .minimax: return "MiniMax"
        case .qianfan: return "百度千帆"
        case .groq: return "Groq"
        case .openrouter: return "OpenRouter"
        case .xai: return "xAI Grok"
        case .mistral: return "Mistral"
        case .together: return "Together AI"
        case .ollama: return "Ollama（本机）"
        case .lmstudio: return "LM Studio（本机）"
        case .custom: return "自定义地址"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .xfyun: return "https://spark-api-open.xf-yun.com/v1"
        case .minimax: return "https://api.minimaxi.com/v1"
        case .qianfan: return "https://qianfan.baidubce.com/v2"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .xai: return "https://api.x.ai/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .together: return "https://api.together.ai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .lmstudio: return "http://localhost:1234/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .deepseek: return "deepseek-chat"
        case .doubao: return "doubao-seed-2-0-mini-260428"
        case .qwen: return "qwen-flash"
        case .moonshot: return "kimi-k2-turbo-preview"
        case .zhipu: return "glm-4.7-flash"
        case .siliconflow: return "Qwen/Qwen3-8B"
        case .xfyun: return "lite"
        case .minimax: return "MiniMax-M2.5-highspeed"
        case .qianfan: return "ernie-4.5-turbo-128k"
        case .groq: return "llama-3.3-70b-versatile"
        case .openrouter: return "openai/gpt-4o-mini"
        case .xai: return "grok-4.3"
        case .mistral: return "mistral-small-latest"
        case .together: return "zai-org/GLM-5.3-Flash"
        case .ollama: return "qwen3:8b"
        case .lmstudio: return ""
        case .custom: return ""
        }
    }

    /// One line under the model field: what the vendor calls its key, or a naming caveat.
    var hint: String? {
        switch self {
        case .doubao: return "模型填「模型 ID」（如 doubao-seed-2-0-mini-260428，须在方舟控制台开通）或接入点 ep-…；已关闭深度思考。"
        case .xfyun: return "Key 填控制台的 APIPassword；模型名 lite / generalv3.5 / 4.0Ultra 与 Key 一一对应。"
        case .qianfan: return "Key 是 bce-v3/ALTAK-… 形式的 IAM API Key。"
        case .minimax: return "模型名以控制台为准（M2.5 / M2.7 highspeed）。"
        case .zhipu: return "glm-4.7-flash 免费；已关闭深度思考。"
        case .qwen: return "已关闭深度思考；翻译专用模型可填 qwen-mt-flash。"
        default: return nil
        }
    }

    /// Localhost presets; a custom address counts as local when its host is this machine.
    var isLocalPreset: Bool { self == .ollama || self == .lmstudio }

    var needsKey: Bool {
        switch self {
        case .ollama, .lmstudio, .custom: return false
        default: return true
        }
    }

    var destination: String {
        switch self {
        case .openai: return "OpenAI（美国）"
        case .deepseek: return "DeepSeek（中国）"
        case .doubao: return "火山引擎（中国）"
        case .qwen: return "阿里云百炼（中国）"
        case .moonshot: return "月之暗面（中国）"
        case .zhipu: return "智谱（中国）"
        case .siliconflow: return "硅基流动（中国）"
        case .xfyun: return "科大讯飞（中国）"
        case .minimax: return "MiniMax（中国）"
        case .qianfan: return "百度智能云（中国）"
        case .groq: return "Groq（美国）"
        case .openrouter: return "OpenRouter（美国）"
        case .xai: return "xAI（美国）"
        case .mistral: return "Mistral（法国）"
        case .together: return "Together（美国）"
        case .ollama, .lmstudio: return "本机"
        case .custom: return "自定义服务"
        }
    }

    /// Vendor-specific body fields that keep reasoning models from thinking aloud. An object
    /// literal is embedded as JSON.
    var extraBody: [String: String] {
        switch self {
        case .qwen, .siliconflow: return ["enable_thinking": "false"]
        case .doubao, .zhipu: return ["thinking": "{\"type\":\"disabled\"}"]
        default: return [:]
        }
    }

    /// Only this machine counts as local; a LAN box (`mini.local`) still receives the text.
    static func isLocalHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// The API keys, read from the Keychain once at launch and again only when one is saved or
/// deleted, so typing in a settings field never touches the Keychain.
struct EngineCredentials: Sendable, Equatable {
    var realtime: String?
    var deepgram: String?
    var anthropic: String?
    var gemini: String?
    var doubaoApp: String?
    var doubaoToken: String?
    var dashscope: String?
    var soniox: String?
    var chat: [String: String]

    static let empty = EngineCredentials(realtime: nil, deepgram: nil, anthropic: nil, gemini: nil, doubaoApp: nil, doubaoToken: nil, dashscope: nil, soniox: nil, chat: [:])

    static func load() -> EngineCredentials {
        var chat: [String: String] = [:]
        for vendor in ChatVendor.allCases {
            if let key = CredentialStore.load(CredentialStore.chat(vendor)) { chat[vendor.rawValue] = key }
        }
        return EngineCredentials(
            realtime: CredentialStore.load(CredentialStore.realtime),
            deepgram: CredentialStore.load(CredentialStore.deepgram),
            anthropic: CredentialStore.load(CredentialStore.anthropic),
            gemini: CredentialStore.load(CredentialStore.gemini),
            doubaoApp: CredentialStore.load(CredentialStore.doubaoApp),
            doubaoToken: CredentialStore.load(CredentialStore.doubaoToken),
            dashscope: CredentialStore.load(CredentialStore.dashscope),
            soniox: CredentialStore.load(CredentialStore.soniox),
            chat: chat
        )
    }
}

/// API keys live in the Keychain, one entry per service; settings only remember that one exists.
enum CredentialStore {
    static let realtime = "openai-realtime"
    static let deepgram = "deepgram"
    static let anthropic = "anthropic"
    static let gemini = "gemini"
    static let doubaoApp = "doubao-app"
    static let doubaoToken = "doubao-token"
    static let dashscope = "dashscope"
    static let soniox = "soniox"
    static func chat(_ vendor: ChatVendor) -> String { "chat.\(vendor.rawValue)" }

    private static func service(_ id: String) -> String { "LiveLearn.key.\(id)" }

    static func load(_ id: String) -> String? {
        KeychainStore.load(service: service(id), account: "apiKey").flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ id: String, key: String) throws {
        try KeychainStore.save(service: service(id), account: "apiKey", secret: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func delete(_ id: String) throws {
        try KeychainStore.delete(service: service(id), account: "apiKey")
    }

    /// "sk-…abcd" for the settings screen; never the whole key.
    static func hint(_ key: String) -> String {
        guard key.count > 8 else { return "已保存" }
        return "已保存 · \(key.prefix(3))…\(key.suffix(4))"
    }
}

/// The readiness of both stages for one direction, for the start gate and the settings screen.
struct EngineReadiness: Equatable {
    var recognizer: StageAvailability
    var translator: StageAvailability

    var isReady: Bool { recognizer.isReady && translator.isReady }
    /// The first thing to fix, recognizer before translator.
    var blocker: String? { recognizer.blocker ?? translator.blocker }
    var summary: String {
        if isReady { return "就绪" }
        return [recognizer.isReady ? nil : "识别未就绪", translator.isReady ? nil : "翻译未就绪"].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Everything the session factory needs, copied out of settings and the Keychain on the main
/// actor so the lane factories (which run off it) never touch either.
struct EngineBlueprint: Sendable, Equatable {
    var recognizer: RecognizerChoice
    var translator: TranslatorChoice
    var whisper: WhisperConfig
    var realtime: OpenAIRealtimeConfig
    var deepgram: DeepgramConfig
    var doubao: DoubaoConfig
    var paraformer: ParaformerConfig
    var soniox: SonioxConfig
    var geminiLive: GeminiLiveConfig
    var chat: OpenAICompatibleConfig
    var anthropic: AnthropicConfig
    var gemini: GeminiConfig
    var recognitionVocabulary: [String]
    var translationVocabulary: [VocabularyTerm]
    /// Translate unfinished sentences on paid backends too (more requests, livelier captions).
    var cloudPartials: Bool

    @MainActor
    init(settings: AppSettings, credentials: EngineCredentials) {
        recognizer = settings.recognizer
        translator = settings.translator
        whisper = WhisperConfig(variant: settings.whisperModel)
        let realtimeKey = credentials.realtime ?? credentials.chat[ChatVendor.openai.rawValue]
        let realtimeURL = URL(string: settings.realtimeBaseURL) ?? URL(string: "wss://api.openai.com/v1/realtime")!
        realtime = OpenAIRealtimeConfig(
            baseURL: realtimeURL,
            apiKey: realtimeKey,
            model: settings.realtimeModel,
            legacyProtocol: settings.realtimeLegacyProtocol,
            displayName: ChatVendor.isLocalHost(realtimeURL) ? "本机实时识别服务" : (realtimeURL.host == "api.openai.com" ? "OpenAI 实时识别" : "兼容实时识别服务"),
            destination: realtimeURL.host == "api.openai.com" ? "OpenAI（美国）" : (realtimeURL.host ?? "自定义服务"),
            isLocal: ChatVendor.isLocalHost(realtimeURL)
        )
        deepgram = DeepgramConfig(apiKey: credentials.deepgram, model: settings.deepgramModel)
        doubao = DoubaoConfig(appKey: credentials.doubaoApp, accessKey: credentials.doubaoToken, resourceID: settings.doubaoResourceID)
        // The DashScope key is the same key the Qwen chat preset uses.
        paraformer = ParaformerConfig(apiKey: credentials.dashscope ?? credentials.chat[ChatVendor.qwen.rawValue], model: settings.paraformerModel)
        soniox = SonioxConfig(apiKey: credentials.soniox, model: settings.sonioxModel)
        geminiLive = GeminiLiveConfig(apiKey: credentials.gemini, model: settings.geminiLiveModel)
        let vendor = settings.chatVendor
        let baseString = settings.chatBaseURL(for: vendor)
        let baseURL = URL(string: baseString) ?? URL(string: vendor.defaultBaseURL) ?? URL(string: "http://localhost:11434/v1")!
        // "Local" is decided by the address, not the preset: an Ollama preset pointed at
        // `mini.local:11434` still sends the text to another machine.
        let local = ChatVendor.isLocalHost(baseURL)
        let hostLabel = baseURL.host ?? "自定义服务"
        chat = OpenAICompatibleConfig(
            vendorID: vendor.rawValue,
            displayName: vendor == .custom ? hostLabel : vendor.label.replacingOccurrences(of: "（本机）", with: ""),
            baseURL: baseURL,
            model: settings.chatModel(for: vendor),
            apiKey: credentials.chat[vendor.rawValue],
            isLocal: local,
            requiresKey: vendor.needsKey,
            destination: (vendor == .custom || (vendor.isLocalPreset && !local)) ? hostLabel : vendor.destination,
            extraBody: vendor.extraBody
        )
        anthropic = AnthropicConfig(model: settings.anthropicModel, apiKey: credentials.anthropic)
        gemini = GeminiConfig(model: settings.geminiModel, apiKey: credentials.gemini)
        cloudPartials = settings.cloudPartialTranslation

        let glossary = GlossaryEntry.parse(settings.glossaryLines)
        recognitionVocabulary = VocabularyMatcher.uniqueWords(settings.hotWords + glossary.map(\.source))
        translationVocabulary = glossary.map { VocabularyTerm(source: $0.source, target: $0.target) }
        // Every lane applies conservative spelling calibration; adapters with native hints
        // also receive the same source terms. Translators share the fixed translations.
        let hotWords = recognitionVocabulary
        if !hotWords.isEmpty {
            realtime.prompt = "Vocabulary: \(hotWords.joined(separator: ", "))."
            deepgram.keyterms = hotWords
            doubao.hotWords = hotWords
            soniox.terms = hotWords
            geminiLive.vocabulary = hotWords
        }
        chat.glossary = glossary
        anthropic.glossary = glossary
        gemini.glossary = glossary
    }

    /// Application support includes spelling calibration for recognizers without hints.
    var vocabularyTakers: (hotWords: Bool, glossary: Bool) {
        (true, true)
    }

    var usesNativeRecognitionVocabulary: Bool {
        ![.appleSpeech, .paraformer].contains(recognizer)
    }

    var vocabularyUsageNote: String {
        let recognition: String
        switch recognizer {
        case .appleSpeech, .paraformer:
            recognition = "识别后在本机校准大小写、空格和连字符；当前接入不向识别模型注入热词，不会猜测替换发音相近的词。"
        case .whisperKit:
            recognition = "将词表作为解码提示，并在本机校准词形；词表较长时，模型优先使用前面的词。"
        default:
            recognition = "向服务提供词表提示，并在本机校准词形；提示效果取决于所选模型。"
        }
        let translation = translator == .appleTranslation
            ? "在本机保护固定译法；macOS 26.4 及以上保留整句翻译，更早版本分段翻译其余内容。"
            : "翻译请求会携带术语表，包含云端渠道与 Ollama、LM Studio 等兼容服务；最终效果取决于模型。"
        return "\(recognizerName)：\(recognition)\n\n\(translatorName)：\(translation)\n\n词汇修改从下次会话开始应用。"
    }

    var recognizerIsLocal: Bool {
        switch recognizer {
        case .appleSpeech, .whisperKit: return true
        case .openAIRealtime: return realtime.isLocal
        case .deepgram, .doubao, .paraformer, .soniox, .geminiLive: return false
        }
    }

    var translatorIsLocal: Bool {
        switch translator {
        case .appleTranslation: return true
        case .chat: return chat.isLocal
        case .anthropic, .gemini: return false
        }
    }

    var isLocal: Bool { recognizerIsLocal && translatorIsLocal }

    var recognizerName: String {
        switch recognizer {
        case .appleSpeech: return "Apple 识别"
        case .whisperKit: return "Whisper 识别"
        case .openAIRealtime: return realtime.isLocal ? "本机实时识别" : "OpenAI 识别"
        case .deepgram, .doubao, .paraformer, .soniox, .geminiLive: return recognizer.shortLabel
        }
    }

    var translatorName: String {
        switch translator {
        case .appleTranslation: return "Apple 翻译"
        case .chat: return "\(chat.displayName) 翻译"
        case .anthropic: return "Claude 翻译"
        case .gemini: return "Gemini 翻译"
        }
    }

    /// "Apple 识别 · Apple 翻译", the sidebar's one-line fact.
    var summary: String { "\(recognizerName) · \(translatorName)" }

    var needsAppleOS: Bool { recognizer == .appleSpeech || translator == .appleTranslation }

    /// What leaves the machine, in one sentence for the empty state and the settings page.
    var dataDestination: String {
        PipelineProvider.dataDestination(recognizer: descriptor(of: recognizer), translator: descriptor(of: translator))
    }

    private func descriptor(of r: RecognizerChoice) -> EngineStageDescriptor {
        switch r {
        case .appleSpeech: return EngineStageDescriptor(id: "apple.speech", displayName: "Apple 本机识别", modelID: "", isLocal: true, dataDestination: "", costUnit: "")
        case .whisperKit: return WhisperKitRecognizer(config: whisper).descriptor
        case .openAIRealtime: return OpenAIRealtimeRecognizer(config: realtime).descriptor
        case .deepgram: return DeepgramRecognizer(config: deepgram).descriptor
        case .doubao: return DoubaoRecognizer(config: doubao).descriptor
        case .paraformer: return ParaformerRecognizer(config: paraformer).descriptor
        case .soniox: return SonioxRecognizer(config: soniox).descriptor
        case .geminiLive: return GeminiLiveRecognizer(config: geminiLive).descriptor
        }
    }

    private func descriptor(of t: TranslatorChoice) -> EngineStageDescriptor {
        switch t {
        case .appleTranslation: return EngineStageDescriptor(id: "apple.translation", displayName: "Apple 本机翻译", modelID: "", isLocal: true, dataDestination: "", costUnit: "")
        case .chat: return OpenAICompatibleTranslator(config: chat).descriptor
        case .anthropic: return AnthropicTranslator(config: anthropic).descriptor
        case .gemini: return GeminiTranslator(config: gemini).descriptor
        }
    }

    // MARK: - Factories (off the main actor)

    func makeRecognizer() throws -> any SpeechRecognizer {
        switch recognizer {
        case .appleSpeech:
            if #available(macOS 26, *) { return AppleSpeechRecognizer() }
            throw ProviderError(.unsupported, "Apple 本机识别需要 macOS 26；请在 设置 › 引擎 中改用其他识别引擎")
        case .whisperKit:
            return WhisperKitRecognizer(config: whisper)
        case .openAIRealtime:
            return OpenAIRealtimeRecognizer(config: realtime)
        case .deepgram:
            return DeepgramRecognizer(config: deepgram)
        case .doubao:
            return DoubaoRecognizer(config: doubao)
        case .paraformer:
            return ParaformerRecognizer(config: paraformer)
        case .soniox:
            return SonioxRecognizer(config: soniox)
        case .geminiLive:
            return GeminiLiveRecognizer(config: geminiLive)
        }
    }

    func makeTranslator() throws -> any TextTranslator {
        switch translator {
        case .appleTranslation:
            if #available(macOS 26, *) { return AppleTextTranslator(glossary: translationVocabulary) }
            throw ProviderError(.unsupported, "Apple 本机翻译需要 macOS 26；请在 设置 › 引擎 中改用其他翻译引擎")
        case .chat:
            return OpenAICompatibleTranslator(config: chat)
        case .anthropic:
            return AnthropicTranslator(config: anthropic)
        case .gemini:
            return GeminiTranslator(config: gemini)
        }
    }

    static let providerID = "pipeline"

    func makeProvider() throws -> PipelineProvider {
        let r = try makeRecognizer()
        let t = try makeTranslator()
        let localTranslator = t.descriptor.isLocal
        return PipelineProvider(
            recognizer: r,
            translator: t,
            providerID: Self.providerID,
            displayName: isLocal ? "本机引擎" : summary,
            translatesPartials: localTranslator || cloudPartials,
            partialIntervalNs: localTranslator ? 700_000_000 : 1_500_000_000,
            vocabulary: recognitionVocabulary
        )
    }

    /// Both stages' readiness for one direction, without opening anything.
    func readiness(source: String?, target: String) async -> EngineReadiness {
        guard let provider = try? makeProvider() else {
            let why = "这台电脑的系统低于 macOS 26，Apple 本机识别 / 翻译不可用；请在 设置 › 引擎 中改用其他引擎。"
            return EngineReadiness(recognizer: recognizer == .appleSpeech ? .blocked(why) : .ready, translator: translator == .appleTranslation ? .blocked(why) : .ready)
        }
        let (r, t) = await provider.availability(source: source, target: target)
        return EngineReadiness(recognizer: r, translator: t)
    }
}
