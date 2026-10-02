import Foundation
import Speech
import Translation
import CaptionDomain

/// Language codes the app offers, mapped to what the two Apple frameworks want.
public enum LocalLanguage {
    /// Every catalog language; whether the OS has assets for one is answered per pair below.
    public static var codes: [String] { LanguageCatalog.codes }

    /// Speech recognition assets are per region locale; the catalog names the mainstream one.
    public static func speechLocale(for code: String) -> Locale? {
        guard code != LanguageCatalog.auto else { return nil }
        return Locale(identifier: LanguageCatalog.speechLocaleIdentifier(for: code))
    }

    public static func translationLanguage(for code: String) -> Locale.Language {
        Locale.Language(identifier: LanguageCatalog.canonical(code))
    }
}

/// What the machine has for one capability, in words the settings screen can show.
public enum AssetState: String, Sendable, Codable, Equatable {
    case installed
    case downloadable
    case downloading
    case unsupported
    /// The framework needs a newer macOS than this one.
    case needsNewerOS

    public var label: String {
        switch self {
        case .installed: return "已安装"
        case .downloadable: return "可下载"
        case .downloading: return "下载中"
        case .unsupported: return "不支持"
        case .needsNewerOS: return "需要 macOS 26"
        }
    }
}

/// Readiness of one language direction on the local engine.
public struct LocalPairStatus: Sendable, Equatable {
    public var source: String
    public var target: String
    public var speech: AssetState
    public var translation: AssetState

    public var isReady: Bool { speech == .installed && translation == .installed }

    /// Why a session cannot start, or nil.
    public var blocker: String? {
        let src = LocalEngineAvailability.name(source)
        let dst = LocalEngineAvailability.name(target)
        switch speech {
        case .needsNewerOS: return "本机识别需要 macOS 26 或更新版本；请在 设置 › 引擎 中改用其他识别引擎，或升级系统。"
        case .unsupported: return "Apple 本机识别不支持\(src)；可在 设置 › 引擎 中改用云端识别。"
        case .downloadable, .downloading: return "\(src)识别模型尚未下载。在 设置 › 本地模型 中下载后即可开始。"
        case .installed: break
        }
        switch translation {
        case .needsNewerOS: return "本机翻译需要 macOS 15 或更新版本。"
        case .unsupported: return "Apple 本机翻译不支持 \(src) → \(dst)；可在 设置 › 引擎 中改用其他翻译引擎。"
        case .downloadable, .downloading: return "\(src) → \(dst) 的翻译语言包尚未下载。在 设置 › 本地模型 中下载后即可开始。"
        case .installed: return nil
        }
    }
}

/// Availability checks for the on-device engine. Every query is read-only; downloads only
/// happen through the explicit request objects below, never as a side effect of starting.
public enum LocalEngineAvailability {
    public static var isSupportedOS: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func name(_ code: String) -> String { LanguageCatalog.name(code) }

    public static func speechState(language code: String) async -> AssetState {
        guard #available(macOS 26, *) else { return .needsNewerOS }
        guard SpeechTranscriber.isAvailable, let locale = LocalLanguage.speechLocale(for: code) else { return .unsupported }
        guard await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else { return .unsupported }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return .installed
        case .downloading:
            return .downloading
        case .unsupported:
            return .unsupported
        case .supported:
            // "supported" is also what an installed system-wide asset reports before this app
            // has touched it; the installation request is nil when nothing needs downloading.
            if let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                return request.progress.fractionCompleted > 0 && !request.progress.isFinished ? .downloading : .downloadable
            }
            return .installed
        @unknown default:
            return .unsupported
        }
    }

    public static func translationState(source: String?, target: String) async -> AssetState {
        guard #available(macOS 15, *) else { return .needsNewerOS }
        guard let source, source != LanguageCatalog.auto else {
            return await automaticTranslationState(target: target) { source, target in
                await translationState(source: source, target: target)
            }
        }
        let availability = LanguageAvailability()
        switch await availability.status(from: LocalLanguage.translationLanguage(for: source), to: LocalLanguage.translationLanguage(for: target)) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    /// Automatic input can start with one installed direction. Each detected language is
    /// checked again before translation, so an unrelated installed pack never masks a gap.
    static func automaticTranslationState(target: String, query: (String, String) async -> AssetState) async -> AssetState {
        var result = AssetState.unsupported
        for source in LanguageCatalog.codes where source != LanguageCatalog.canonical(target) {
            let state = await query(source, target)
            if state == .installed { return .installed }
            if state == .downloadable { result = .downloadable }
        }
        return result
    }

    public static func status(source: String, target: String) async -> LocalPairStatus {
        async let speech = speechState(language: source)
        async let translation = translationState(source: source, target: target)
        return await LocalPairStatus(source: source, target: target, speech: speech, translation: translation)
    }

    /// Speech assets for one language. Returns nil when nothing needs downloading. The caller
    /// shows `progress` and awaits `downloadAndInstall()`; the system decides the size.
    @available(macOS 26, *)
    public static func speechInstallationRequest(language code: String) async throws -> AssetInstallationRequest? {
        guard let locale = LocalLanguage.speechLocale(for: code) else {
            throw ProviderErrorShim.unsupported("不支持的语言 \(code)")
        }
        // Reservation keeps the assets from being purged while this app relies on them.
        _ = try? await AssetInventory.reserve(locale: locale)
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return try await AssetInventory.assetInstallationRequest(supporting: [module])
    }
}

/// Small error type for availability helpers that do not have a provider context.
enum ProviderErrorShim: Error, CustomStringConvertible {
    case unsupported(String)
    var description: String {
        switch self { case .unsupported(let s): return s }
    }
}
