import Foundation

enum OptionalModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case textTranslation, dictation, browserExtension
    var id: String { rawValue }
    var title: String {
        switch self {
        case .textTranslation: "划词与文字翻译"
        case .dictation: "语音输入"
        case .browserExtension: "网页翻译"
        }
    }
    var detail: String {
        switch self {
        case .textTranslation: "选中文字、截图，或打开一个小小的翻译窗。"
        case .dictation: "把想说的话，写进正在使用的输入框。"
        case .browserExtension: "在浏览器里，把网页变成双语读物。"
        }
    }
    var symbol: String {
        switch self {
        case .textTranslation: "character.cursor.ibeam"
        case .dictation: "waveform"
        case .browserExtension: "globe"
        }
    }
    var settingsTab: SettingsTab {
        switch self {
        case .textTranslation: .textTranslation
        case .dictation: .dictation
        case .browserExtension: .browserExtension
        }
    }
    var requiredPaths: [String] {
        switch self {
        case .textTranslation: ["Helpers/LiveLearnTranslation.app/Contents/MacOS/LiveLearnTranslation", "PlugIns/LiveLearnTranslationSettings.bundle/Contents/MacOS/LiveLearnTranslationSettings"]
        case .dictation: ["Helpers/LiveLearnDictation", "Frameworks/libopus.0.dylib"]
        case .browserExtension: ["BrowserExtension/package.json", "BrowserExtension/chromium.zip"]
        }
    }
}

struct ModuleArtifact: Codable, Equatable, Sendable {
    let id: OptionalModule
    let version: String
    let url: URL
    let sha256: String
    let bytes: Int64
    let expandedBytes: Int64
    let minimumMacOS: Int
    let architecture: String
    let apiVersion: Int
}

struct ModuleCatalog: Codable, Sendable {
    let schema: Int
    let modules: [ModuleArtifact]
}

struct SignedModuleCatalog: Codable {
    let payload: Data
    let signature: Data
}

struct ModuleTrust: Codable, Sendable {
    let catalogURL: URL
    let publicKey: Data
}

enum ModuleInstallError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
