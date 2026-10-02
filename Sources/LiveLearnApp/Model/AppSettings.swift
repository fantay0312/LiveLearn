import Foundation
import Observation
import CaptionDomain
import LocalEngine
import WhisperEngine

/// Which settings tab to show when the app opens Settings on the user's behalf.
/// Raw values are stable (a stored one must keep opening the same page); the page order is
/// the list in `SettingsView`, not this order.
enum SettingsTab: Int {
    case sources = 0, language, engine, localModels, appearance, privacy, diagnostics
    case vocabulary = 7
    case shortcuts = 8
    case theme = 9
    case browserExtension = 10
    case textTranslation = 11
    case dictation = 12
    case modules = 13

    var navigationPage: LiveLearnSettingsPage? {
        LiveLearnSettingsPage.allCases.first { $0.settingsTab == self }
    }
}

extension LiveLearnSettingsPage {
    var settingsTab: SettingsTab {
        switch self {
        case .sources: .sources
        case .language: .language
        case .engine: .engine
        case .localModels: .localModels
        case .appearance: .appearance
        case .shortcuts: .shortcuts
        case .privacy: .privacy
        case .diagnostics: .diagnostics
        case .theme: .theme
        case .textTranslation: .textTranslation
        case .browserExtension: .browserExtension
        case .dictation: .dictation
        case .modules: .modules
        }
    }
}

enum CaptionStability: String, CaseIterable, Identifiable {
    case responsive, balanced, steady
    var id: String { rawValue }
    var label: String {
        switch self {
        case .responsive: return "响应"
        case .balanced: return "平衡"
        case .steady: return "稳定"
        }
    }
    var note: String {
        switch self {
        case .responsive: return "字幕更新最快，改动也最多"
        case .balanced: return "默认；稍等片刻再显示，减少来回改写"
        case .steady: return "只显示相对稳定的内容，阅读最省力"
        }
    }
    /// Minimum dwell before the overlay replaces a preview line, in ms.
    var previewDwellMs: Int {
        switch self {
        case .responsive: return 100
        case .balanced: return 220
        case .steady: return 450
        }
    }
}

enum OverlayTextWeight: String, CaseIterable, Identifiable {
    case regular, medium, semibold
    var id: String { rawValue }
    var label: String {
        switch self {
        case .regular: return "常规"
        case .medium: return "中等"
        case .semibold: return "半粗"
        }
    }
}

enum OverlayPlacement: String, CaseIterable, Identifiable {
    case bottom, top
    var id: String { rawValue }
    var label: String { self == .bottom ? "底部" : "顶部" }
}

enum CaptionPresentation: String, CaseIterable, Identifiable {
    case layered, singleLine
    var id: String { rawValue }
    var label: String { self == .layered ? "分层显示" : "单行字幕" }
    var note: String {
        self == .layered ? "当前句突出显示，上下文与原文分层呈现。"
            : "像视频字幕一样逐句切换，长句自动分段；始终只显示一行。"
    }
}

enum OverlayCloseAction: String, CaseIterable, Identifiable {
    case endSession, pause
    var id: String { rawValue }
    var label: String { self == .endSession ? "结束会话" : "暂停会话" }
    var note: String {
        self == .endSession
            ? "停止音频采集并结束会话，保留已有记录。"
            : "暂停向引擎送音频，保留会话和音源连接，需要手动继续；释放音源请选择结束会话。"
    }
}

enum SessionMode: String, CaseIterable, Identifiable {
    case listen, converse, faceToFace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .listen: return "听懂电脑里的内容"
        case .converse: return "和别人交流"
        case .faceToFace: return "面对面"
        }
    }
    var note: String {
        switch self {
        case .listen: return "把某个应用或系统声音变成字幕；不需要麦克风"
        case .converse: return "我说的话译给对方，对方的话译给我；两条独立通道"
        case .faceToFace: return "一个麦克风，指定方向；多人归属不保证准确"
        }
    }
}

/// Persisted preferences. Plain UserDefaults; nothing here is secret.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults
    let dictation: DictationSettings
    let modules: ModuleLibrary
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: "onboarding.completed.v1") } }
    var onboardingSound: Bool { didSet { defaults.set(onboardingSound, forKey: "onboarding.sound") } }

    var settingsMode: SettingsMode {
        didSet {
            defaults.set(settingsMode.rawValue, forKey: "settingsMode")
            if !settingsMode.isDeveloper, requestedSettingsTab == .diagnostics { requestedSettingsTab = .privacy }
        }
    }

    var experienceTheme: ExperienceTheme { didSet { defaults.set(experienceTheme.rawValue, forKey: "experienceTheme") } }
    var interfaceSize: InterfaceSize { didSet { defaults.set(interfaceSize.rawValue, forKey: "interfaceSize") } }
    var showBackgroundScene: Bool { didSet { defaults.set(showBackgroundScene, forKey: "showBackgroundScene") } }

    var captionTargetSize: Double { didSet { defaults.set(captionTargetSize, forKey: "captionTargetSize") } }
    var captionSourceSize: Double { didSet { defaults.set(captionSourceSize, forKey: "captionSourceSize") } }
    var captionPresentation: CaptionPresentation { didSet { defaults.set(captionPresentation.rawValue, forKey: "captionPresentation") } }
    var singleLineWidth: Double { didSet { defaults.set(singleLineWidth, forKey: "singleLineWidth") } }
    var captionDisplayWidth: Double {
        get { captionPresentation == .singleLine ? singleLineWidth : overlayWidth }
        set {
            if captionPresentation == .singleLine { singleLineWidth = newValue }
            else { overlayWidth = newValue }
        }
    }
    var stability: CaptionStability { didSet { defaults.set(stability.rawValue, forKey: "stability") } }
    var showPreviousLine: Bool { didSet { defaults.set(showPreviousLine, forKey: "showPreviousLine") } }
    var showBreathLine: Bool { didSet { defaults.set(showBreathLine, forKey: "showBreathLine") } }
    var showSourceInOverlay: Bool { didSet { defaults.set(showSourceInOverlay, forKey: "showSourceInOverlay") } }
    var overlayPlacement: OverlayPlacement { didSet { defaults.set(overlayPlacement.rawValue, forKey: "overlayPlacement") } }
    var controlSessionOnOverlayClose: Bool { didSet { defaults.set(controlSessionOnOverlayClose, forKey: "controlSessionOnOverlayClose") } }
    var overlayCloseAction: OverlayCloseAction { didSet { defaults.set(overlayCloseAction.rawValue, forKey: "overlayCloseAction") } }
    var readingSerif: Bool { didSet { defaults.set(readingSerif, forKey: "readingSerif") } }
    var keepRunningWhenWindowCloses: Bool { didSet { defaults.set(keepRunningWhenWindowCloses, forKey: "keepRunningWhenWindowCloses") } }
    /// Off by default: nothing is written until the user opts in (or saves one record by hand).
    var autoSaveSessions: Bool { didSet { defaults.set(autoSaveSessions, forKey: "autoSaveSessions") } }
    // Engine stages. Keys are in the Keychain (`CredentialStore`); only non-secrets live here.
    var recognizer: RecognizerChoice { didSet { defaults.set(recognizer.rawValue, forKey: "recognizer") } }
    var translator: TranslatorChoice { didSet { defaults.set(translator.rawValue, forKey: "translator") } }
    /// WhisperKit model folder name (`WhisperVariant.id`).
    var whisperModel: String { didSet { defaults.set(whisperModel, forKey: "whisperModel") } }
    var chatVendor: ChatVendor { didSet { defaults.set(chatVendor.rawValue, forKey: "chatVendor") } }
    /// Per-vendor overrides; a vendor without one uses its preset.
    private(set) var chatBaseURLs: [String: String] { didSet { defaults.set(chatBaseURLs, forKey: "chatBaseURLs") } }
    private(set) var chatModels: [String: String] { didSet { defaults.set(chatModels, forKey: "chatModels") } }
    var realtimeBaseURL: String { didSet { defaults.set(realtimeBaseURL, forKey: "realtimeBaseURL") } }
    var realtimeModel: String { didSet { defaults.set(realtimeModel, forKey: "realtimeModel") } }
    var realtimeLegacyProtocol: Bool { didSet { defaults.set(realtimeLegacyProtocol, forKey: "realtimeLegacyProtocol") } }
    var deepgramModel: String { didSet { defaults.set(deepgramModel, forKey: "deepgramModel") } }
    var doubaoResourceID: String { didSet { defaults.set(doubaoResourceID, forKey: "doubaoResourceID") } }
    var paraformerModel: String { didSet { defaults.set(paraformerModel, forKey: "paraformerModel") } }
    var sonioxModel: String { didSet { defaults.set(sonioxModel, forKey: "sonioxModel") } }
    var geminiLiveModel: String { didSet { defaults.set(geminiLiveModel, forKey: "geminiLiveModel") } }
    /// 词汇: terms the recognizers are primed with, and `源=译` lines the translators must honour.
    var hotWords: [String] { didSet { defaults.set(hotWords, forKey: "hotWords") } }
    var glossaryLines: [String] { didSet { defaults.set(glossaryLines, forKey: "glossaryLines") } }
    var vocabularyWindowPinned: Bool { didSet { defaults.set(vocabularyWindowPinned, forKey: "vocabularyWindowPinned") } }
    /// 朗读译文: speak each finalized translation of the computer / microphone channel.
    var readAloudComputer: Bool { didSet { defaults.set(readAloudComputer, forKey: "readAloudComputer") } }
    var readAloudMicrophone: Bool { didSet { defaults.set(readAloudMicrophone, forKey: "readAloudMicrophone") } }
    var anthropicModel: String { didSet { defaults.set(anthropicModel, forKey: "anthropicModel") } }
    var geminiModel: String { didSet { defaults.set(geminiModel, forKey: "geminiModel") } }
    /// Paid translators translate unfinished sentences too (more requests, livelier captions).
    var cloudPartialTranslation: Bool { didSet { defaults.set(cloudPartialTranslation, forKey: "cloudPartialTranslation") } }
    /// 快捷键 (§9.4): per action, `[keyCode, modifiers]`, only for the actions the user has
    /// bound. Nothing ships bound; a missing entry is "not set".
    private(set) var hotKeys: [String: [Int]] { didSet { defaults.set(hotKeys, forKey: "hotKeys") } }

    func hotKey(for action: HotKeyAction) -> KeyCombo? {
        hotKeys[action.rawValue].flatMap { KeyCombo(stored: $0) }
    }

    /// nil clears the action.
    func setHotKey(_ combo: KeyCombo?, for action: HotKeyAction) {
        hotKeys[action.rawValue] = combo?.stored
    }

    func clearHotKeys() { hotKeys = [:] }

    /// Every action that has a combination right now.
    var hotKeyBindings: [HotKeyAction: KeyCombo] {
        var out: [HotKeyAction: KeyCombo] = [:]
        for action in HotKeyAction.allCases {
            if let combo = hotKey(for: action) { out[action] = combo }
        }
        return out
    }

    /// The other action already using this combination, if any.
    func hotKeyOwner(of combo: KeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && hotKey(for: $0) == combo }
    }

    /// Not persisted: bumped whenever a key is saved or deleted, so the model rebuilds its blueprint.
    var credentialsVersion = 0
    /// Not persisted: the tab Settings should open on next presentation.
    var requestedSettingsTab: SettingsTab = .sources
    /// Ephemeral request from an inline editor to reveal the top of its settings page.
    var settingsScrollRequest = 0

    func chatBaseURL(for vendor: ChatVendor) -> String {
        let custom = chatBaseURLs[vendor.rawValue] ?? ""
        return custom.isEmpty ? vendor.defaultBaseURL : custom
    }

    func setChatBaseURL(_ url: String, for vendor: ChatVendor) {
        chatBaseURLs[vendor.rawValue] = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func chatModel(for vendor: ChatVendor) -> String {
        chatModels[vendor.rawValue] ?? vendor.defaultModel
    }

    func setChatModel(_ model: String, for vendor: ChatVendor) {
        chatModels[vendor.rawValue] = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var overlayOpaque: Bool { didSet { defaults.set(overlayOpaque, forKey: "overlayOpaque") } }
    /// Only the caption background fades; text and hover controls stay legible.
    var overlayBackgroundHex: String { didSet { defaults.set(overlayBackgroundHex, forKey: "overlayBackgroundHex") } }
    var overlayOpacity: Double { didSet { defaults.set(overlayOpacity, forKey: "overlayOpacity") } }
    var overlayTextHex: String { didSet { defaults.set(overlayTextHex, forKey: "overlayTextHex") } }
    /// Empty means "derive from the translation color at 70%".
    var overlaySourceHex: String { didSet { defaults.set(overlaySourceHex, forKey: "overlaySourceHex") } }
    var overlayWidth: Double { didSet { defaults.set(overlayWidth, forKey: "overlayWidth") } }
    var overlayTextWeight: OverlayTextWeight { didSet { defaults.set(overlayTextWeight.rawValue, forKey: "overlayTextWeight") } }
    /// Empty selects the system font; other values are installed font family names.
    var overlayFontFamily: String { didSet { defaults.set(overlayFontFamily, forKey: "overlayFontFamily") } }
    var overlayTextAlignment: OverlayTextAlignment { didSet { defaults.set(overlayTextAlignment.rawValue, forKey: "overlayTextAlignment") } }
    var overlayLineSpacing: OverlayLineSpacing { didSet { defaults.set(overlayLineSpacing.rawValue, forKey: "overlayLineSpacing") } }
    var overlayContrastMode: OverlayContrastMode { didSet { defaults.set(overlayContrastMode.rawValue, forKey: "overlayContrastMode") } }
    var overlayOutlineHex: String { didSet { defaults.set(overlayOutlineHex, forKey: "overlayOutlineHex") } }
    var overlayOutlineWidth: Double { didSet { defaults.set(overlayOutlineWidth, forKey: "overlayOutlineWidth") } }

    static let defaultOverlayBackgroundHex = "12110F"
    static let defaultOverlayOpacity = 0.0
    static let defaultOverlayTextHex = "F4F0E8"
    static let defaultOverlayWidth = 880.0

    func resetOverlayStyle() {
        overlayBackgroundHex = Self.defaultOverlayBackgroundHex
        overlayOpacity = Self.defaultOverlayOpacity
        overlayTextHex = Self.defaultOverlayTextHex
        overlaySourceHex = ""
        overlayWidth = Self.defaultOverlayWidth
        singleLineWidth = 640
        overlayTextWeight = .medium
        overlayFontFamily = ""
        overlayTextAlignment = .center
        overlayLineSpacing = .standard
        overlayContrastMode = .automatic
        overlayOutlineHex = "000000"
        overlayOutlineWidth = 0
        captionTargetSize = 26
        captionSourceSize = 17
        overlayOpaque = false
        showPreviousLine = false
        showBreathLine = false
    }

    /// Applications ticked for the computer channel, in the order they were ticked.
    var lastAppBundleIDs: [String] { didSet { defaults.set(lastAppBundleIDs, forKey: "lastAppBundleIDs") } }
    /// True when the computer channel listens to the ticked applications rather than all of them.
    var listenToApplications: Bool { didSet { defaults.set(listenToApplications, forKey: "listenToApplications") } }
    var lastMicUID: String? { didSet { defaults.set(lastMicUID, forKey: "lastMicUID") } }
    var listenSourceLanguage: String { didSet { defaults.set(listenSourceLanguage, forKey: "listenSourceLanguage") } }
    var listenTargetLanguage: String { didSet { defaults.set(listenTargetLanguage, forKey: "listenTargetLanguage") } }
    var micSourceLanguage: String { didSet { defaults.set(micSourceLanguage, forKey: "micSourceLanguage") } }
    var micTargetLanguage: String { didSet { defaults.set(micTargetLanguage, forKey: "micTargetLanguage") } }
    var mode: SessionMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }

    init(defaults: UserDefaults = .standard) {
        settingsMode = SettingsMode(rawValue: defaults.string(forKey: "settingsMode") ?? "") ?? .standard
        self.defaults = defaults
        self.dictation = DictationSettings(defaults: defaults)
        self.modules = defaults === UserDefaults.standard ? .shared : ModuleLibrary(defaults: defaults)
        self.onboardingCompleted = defaults.bool(forKey: "onboarding.completed.v1")
        self.onboardingSound = defaults.bool(forKey: "onboarding.sound")
        experienceTheme = ExperienceTheme(rawValue: defaults.string(forKey: "experienceTheme") ?? "") ?? .stellar
        interfaceSize = InterfaceSize(rawValue: defaults.string(forKey: "interfaceSize") ?? "") ?? .automatic
        showBackgroundScene = defaults.object(forKey: "showBackgroundScene") as? Bool ?? false
        captionTargetSize = defaults.object(forKey: "captionTargetSize") as? Double ?? 26
        captionSourceSize = defaults.object(forKey: "captionSourceSize") as? Double ?? 17
        captionPresentation = CaptionPresentation(rawValue: defaults.string(forKey: "captionPresentation") ?? "") ?? .layered
        singleLineWidth = defaults.object(forKey: "singleLineWidth") as? Double ?? 640
        stability = CaptionStability(rawValue: defaults.string(forKey: "stability") ?? "") ?? .balanced
        showPreviousLine = defaults.object(forKey: "showPreviousLine") as? Bool ?? false
        showBreathLine = defaults.object(forKey: "showBreathLine") as? Bool ?? false
        showSourceInOverlay = defaults.object(forKey: "showSourceInOverlay") as? Bool ?? true
        overlayPlacement = OverlayPlacement(rawValue: defaults.string(forKey: "overlayPlacement") ?? "") ?? .bottom
        controlSessionOnOverlayClose = defaults.object(forKey: "controlSessionOnOverlayClose") as? Bool ?? false
        overlayCloseAction = OverlayCloseAction(rawValue: defaults.string(forKey: "overlayCloseAction") ?? "") ?? .endSession
        readingSerif = defaults.object(forKey: "readingSerif") as? Bool ?? false
        keepRunningWhenWindowCloses = defaults.object(forKey: "keepRunningWhenWindowCloses") as? Bool ?? true
        autoSaveSessions = defaults.object(forKey: "autoSaveSessions") as? Bool ?? false
        // All sessions now use the configured stages; discard the obsolete mode preference.
        defaults.removeObject(forKey: "engine")
        recognizer = RecognizerChoice(rawValue: defaults.string(forKey: "recognizer") ?? "") ?? .appleSpeech
        translator = TranslatorChoice(rawValue: defaults.string(forKey: "translator") ?? "") ?? .appleTranslation
        whisperModel = defaults.string(forKey: "whisperModel") ?? WhisperVariant.defaultID
        chatVendor = ChatVendor(rawValue: defaults.string(forKey: "chatVendor") ?? "") ?? .openai
        chatBaseURLs = defaults.dictionary(forKey: "chatBaseURLs") as? [String: String] ?? [:]
        chatModels = defaults.dictionary(forKey: "chatModels") as? [String: String] ?? [:]
        realtimeBaseURL = defaults.string(forKey: "realtimeBaseURL") ?? "wss://api.openai.com/v1/realtime"
        realtimeModel = defaults.string(forKey: "realtimeModel") ?? "gpt-4o-transcribe"
        realtimeLegacyProtocol = defaults.object(forKey: "realtimeLegacyProtocol") as? Bool ?? false
        deepgramModel = defaults.string(forKey: "deepgramModel") ?? "nova-3"
        doubaoResourceID = defaults.string(forKey: "doubaoResourceID") ?? "volc.bigasr.sauc.duration"
        paraformerModel = defaults.string(forKey: "paraformerModel") ?? "paraformer-realtime-v2"
        sonioxModel = defaults.string(forKey: "sonioxModel") ?? "stt-rt-v5"
        geminiLiveModel = defaults.string(forKey: "geminiLiveModel") ?? "gemini-3.5-transcribe-live"
        hotWords = defaults.stringArray(forKey: "hotWords") ?? []
        glossaryLines = defaults.stringArray(forKey: "glossaryLines") ?? []
        vocabularyWindowPinned = defaults.object(forKey: "vocabularyWindowPinned") as? Bool ?? false
        readAloudComputer = defaults.object(forKey: "readAloudComputer") as? Bool ?? false
        readAloudMicrophone = defaults.object(forKey: "readAloudMicrophone") as? Bool ?? false
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? "claude-opus-5"
        geminiModel = defaults.string(forKey: "geminiModel") ?? "gemini-2.5-flash"
        cloudPartialTranslation = defaults.object(forKey: "cloudPartialTranslation") as? Bool ?? false
        hotKeys = defaults.dictionary(forKey: "hotKeys") as? [String: [Int]] ?? [:]
        overlayOpaque = defaults.object(forKey: "overlayOpaque") as? Bool ?? false
        overlayBackgroundHex = defaults.string(forKey: "overlayBackgroundHex") ?? Self.defaultOverlayBackgroundHex
        overlayOpacity = defaults.object(forKey: "overlayOpacity") as? Double ?? Self.defaultOverlayOpacity
        overlayTextHex = defaults.string(forKey: "overlayTextHex") ?? Self.defaultOverlayTextHex
        overlaySourceHex = defaults.string(forKey: "overlaySourceHex") ?? ""
        overlayWidth = defaults.object(forKey: "overlayWidth") as? Double ?? Self.defaultOverlayWidth
        overlayTextWeight = OverlayTextWeight(rawValue: defaults.string(forKey: "overlayTextWeight") ?? "") ?? .medium
        overlayFontFamily = defaults.string(forKey: "overlayFontFamily") ?? ""
        overlayTextAlignment = OverlayTextAlignment(rawValue: defaults.string(forKey: "overlayTextAlignment") ?? "") ?? .center
        overlayLineSpacing = OverlayLineSpacing(rawValue: defaults.string(forKey: "overlayLineSpacing") ?? "") ?? .standard
        overlayContrastMode = OverlayContrastMode(rawValue: defaults.string(forKey: "overlayContrastMode") ?? "") ?? .automatic
        overlayOutlineHex = defaults.string(forKey: "overlayOutlineHex") ?? "000000"
        let outlineWidth = defaults.object(forKey: "overlayOutlineWidth") as? Double ?? 0
        overlayOutlineWidth = outlineWidth.isFinite ? min(3, max(0, outlineWidth)) : 0
        // Older builds kept one app under "lastAppBundleID"; carry it into the list once.
        lastAppBundleIDs = defaults.stringArray(forKey: "lastAppBundleIDs") ?? defaults.string(forKey: "lastAppBundleID").map { [$0] } ?? []
        listenToApplications = defaults.object(forKey: "listenToApplications") as? Bool ?? false
        lastMicUID = defaults.string(forKey: "lastMicUID")
        listenSourceLanguage = defaults.string(forKey: "listenSourceLanguage") ?? "en"
        listenTargetLanguage = defaults.string(forKey: "listenTargetLanguage") ?? "zh-Hans"
        micSourceLanguage = defaults.string(forKey: "micSourceLanguage") ?? "zh-Hans"
        micTargetLanguage = defaults.string(forKey: "micTargetLanguage") ?? "en"
        mode = SessionMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .listen
        if dictation.holdWithFn {
            let fn = KeyCombo(keyCode: UInt16(63), modifiers: 0)
            if hotKey(for: .holdDictation) == nil, hotKeyOwner(of: fn, excluding: .holdDictation) == nil {
                setHotKey(fn, for: .holdDictation)
            }
            dictation.holdWithFn = false
        }
    }

    /// Every language the menus offer, from the shared catalog (common ones first).
    static var languages: [LanguageInfo] { LanguageCatalog.all }
}
