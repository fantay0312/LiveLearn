import Foundation

/// One language the app can name. `code` is the BCP-47 tag stored in settings, lane
/// configurations, caption events and archives; the names are what people read.
public struct LanguageInfo: Sendable, Hashable, Identifiable {
    public let code: String
    /// Name in the app's own language (中文).
    public let name: String
    /// Name an English-prompted model understands ("Simplified Chinese").
    public let englishName: String
    /// The regional locale Apple's speech assets are filed under ("zh_CN").
    public let speechLocaleIdentifier: String
    /// Shown at the top of menus; the rest sit under "更多语言".
    public let isCommon: Bool

    public var id: String { code }
}

/// Every language the product offers, in menu order. Whether an engine can actually handle a
/// pair is the engine's business (the local engine asks the OS for its assets; cloud engines
/// declare their own sheets); the catalog only names languages and never promises support.
public enum LanguageCatalog {
    /// Pseudo-code for "let the recognizer detect the source language". Only recognizers that
    /// declare `sourceAutoDetect == .supported` accept it; it is never a target.
    public static let auto = "auto"

    public static let all: [LanguageInfo] = [
        // "中文" alone means Simplified, the default this product is written in; the other
        // script says so. Short names keep "英语 → 中文" one glance wide in the sidebar and bar.
        LanguageInfo(code: "zh-Hans", name: "中文", englishName: "Simplified Chinese", speechLocaleIdentifier: "zh_CN", isCommon: true),
        LanguageInfo(code: "zh-Hant", name: "繁体中文", englishName: "Traditional Chinese", speechLocaleIdentifier: "zh_TW", isCommon: true),
        LanguageInfo(code: "en", name: "英语", englishName: "English", speechLocaleIdentifier: "en_US", isCommon: true),
        LanguageInfo(code: "ja", name: "日语", englishName: "Japanese", speechLocaleIdentifier: "ja_JP", isCommon: true),
        LanguageInfo(code: "ko", name: "韩语", englishName: "Korean", speechLocaleIdentifier: "ko_KR", isCommon: true),
        LanguageInfo(code: "es", name: "西班牙语", englishName: "Spanish", speechLocaleIdentifier: "es_ES", isCommon: true),
        LanguageInfo(code: "fr", name: "法语", englishName: "French", speechLocaleIdentifier: "fr_FR", isCommon: true),
        LanguageInfo(code: "de", name: "德语", englishName: "German", speechLocaleIdentifier: "de_DE", isCommon: true),
        LanguageInfo(code: "yue", name: "粤语", englishName: "Cantonese", speechLocaleIdentifier: "yue_CN", isCommon: false),
        LanguageInfo(code: "pt-BR", name: "葡萄牙语（巴西）", englishName: "Brazilian Portuguese", speechLocaleIdentifier: "pt_BR", isCommon: false),
        LanguageInfo(code: "pt-PT", name: "葡萄牙语（葡萄牙）", englishName: "European Portuguese", speechLocaleIdentifier: "pt_PT", isCommon: false),
        LanguageInfo(code: "it", name: "意大利语", englishName: "Italian", speechLocaleIdentifier: "it_IT", isCommon: false),
        LanguageInfo(code: "ru", name: "俄语", englishName: "Russian", speechLocaleIdentifier: "ru_RU", isCommon: false),
        LanguageInfo(code: "ar", name: "阿拉伯语", englishName: "Arabic", speechLocaleIdentifier: "ar_SA", isCommon: false),
        LanguageInfo(code: "hi", name: "印地语", englishName: "Hindi", speechLocaleIdentifier: "hi_IN", isCommon: false),
        LanguageInfo(code: "th", name: "泰语", englishName: "Thai", speechLocaleIdentifier: "th_TH", isCommon: false),
        LanguageInfo(code: "vi", name: "越南语", englishName: "Vietnamese", speechLocaleIdentifier: "vi_VN", isCommon: false),
        LanguageInfo(code: "id", name: "印尼语", englishName: "Indonesian", speechLocaleIdentifier: "id_ID", isCommon: false),
        LanguageInfo(code: "ms", name: "马来语", englishName: "Malay", speechLocaleIdentifier: "ms_MY", isCommon: false),
        LanguageInfo(code: "nl", name: "荷兰语", englishName: "Dutch", speechLocaleIdentifier: "nl_NL", isCommon: false),
        LanguageInfo(code: "pl", name: "波兰语", englishName: "Polish", speechLocaleIdentifier: "pl_PL", isCommon: false),
        LanguageInfo(code: "tr", name: "土耳其语", englishName: "Turkish", speechLocaleIdentifier: "tr_TR", isCommon: false),
        LanguageInfo(code: "uk", name: "乌克兰语", englishName: "Ukrainian", speechLocaleIdentifier: "uk_UA", isCommon: false),
        LanguageInfo(code: "sv", name: "瑞典语", englishName: "Swedish", speechLocaleIdentifier: "sv_SE", isCommon: false),
        LanguageInfo(code: "da", name: "丹麦语", englishName: "Danish", speechLocaleIdentifier: "da_DK", isCommon: false),
        LanguageInfo(code: "nb", name: "挪威语", englishName: "Norwegian", speechLocaleIdentifier: "nb_NO", isCommon: false),
        LanguageInfo(code: "fi", name: "芬兰语", englishName: "Finnish", speechLocaleIdentifier: "fi_FI", isCommon: false),
        LanguageInfo(code: "cs", name: "捷克语", englishName: "Czech", speechLocaleIdentifier: "cs_CZ", isCommon: false),
        LanguageInfo(code: "el", name: "希腊语", englishName: "Greek", speechLocaleIdentifier: "el_GR", isCommon: false),
        LanguageInfo(code: "he", name: "希伯来语", englishName: "Hebrew", speechLocaleIdentifier: "he_IL", isCommon: false),
        LanguageInfo(code: "hu", name: "匈牙利语", englishName: "Hungarian", speechLocaleIdentifier: "hu_HU", isCommon: false),
        LanguageInfo(code: "ro", name: "罗马尼亚语", englishName: "Romanian", speechLocaleIdentifier: "ro_RO", isCommon: false),
    ]

    public static var common: [LanguageInfo] { all.filter(\.isCommon) }
    public static var more: [LanguageInfo] { all.filter { !$0.isCommon } }
    public static var codes: [String] { all.map(\.code) }

    private static let byCode: [String: LanguageInfo] = {
        var out: [String: LanguageInfo] = [:]
        for l in all { out[l.code] = l }
        // Aliases older settings and engine probes may still use.
        out["zh"] = out["zh-Hans"]
        out["zh_CN"] = out["zh-Hans"]
        out["zh_TW"] = out["zh-Hant"]
        out["en_US"] = out["en"]
        out["ja_JP"] = out["ja"]
        out["ko_KR"] = out["ko"]
        out["pt"] = out["pt-BR"]
        return out
    }()

    public static func info(for code: String) -> LanguageInfo? { byCode[code] }

    /// "中文（简体）", "自动" for the auto pseudo-code, the raw code when unknown.
    public static func name(_ code: String?) -> String {
        guard let code else { return "自动" }
        if code == auto { return "自动" }
        return byCode[code]?.name ?? code
    }

    /// "Simplified Chinese"; the raw code when unknown (a model can usually cope with a tag).
    public static func englishName(_ code: String) -> String {
        byCode[code]?.englishName ?? code
    }

    /// The canonical BCP-47 code for an alias ("zh" → "zh-Hans"); unknown codes pass through.
    public static func canonical(_ code: String) -> String {
        byCode[code]?.code ?? code
    }

    /// The regional locale Apple's speech assets use; a plain `Locale(identifier: code)` when
    /// the catalog has no better idea, so an unknown code still reaches the availability check.
    public static func speechLocaleIdentifier(for code: String) -> String {
        byCode[code]?.speechLocaleIdentifier ?? code
    }
}
