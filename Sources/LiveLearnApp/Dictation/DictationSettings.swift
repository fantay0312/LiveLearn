import Foundation
import Observation
import CloudEngine
import EngineKit

@MainActor @Observable
final class DictationSettings {
    private let defaults: UserDefaults
    static let optimizedEngine = "typelessOptimized"
    static let chatterflyEngine = "chatterfly"
    let chatterflyDeviceID: String
    var engine: String { didSet { defaults.set(engine, forKey: "dictation.engine") } }
    var language: String { didSet { defaults.set(language, forKey: "dictation.language") } }
    var liveInsertion: Bool { didSet { defaults.set(liveInsertion, forKey: "dictation.liveInsertion") } }
    var finalCorrection: Bool { didSet { defaults.set(finalCorrection, forKey: "dictation.finalCorrection") } }
    var holdWithFn: Bool { didSet { defaults.set(holdWithFn, forKey: "dictation.holdWithFn") } }
    var nearInput: Bool { didSet { defaults.set(nearInput, forKey: "dictation.nearInput") } }
    var compatiblePaste: Bool { didSet { defaults.set(compatiblePaste, forKey: "dictation.compatiblePaste") } }
    var refinementBaseURL: String { didSet { defaults.set(refinementBaseURL, forKey: "dictation.refinementBaseURL") } }
    var refinementModel: String { didSet { defaults.set(refinementModel, forKey: "dictation.refinementModel") } }
    var replacements: String { didSet { defaults.set(replacements, forKey: "dictation.replacements") } }
    var optimizedURL: String { didSet { defaults.set(optimizedURL, forKey: "dictation.optimizedURL") } }
    var optimizedAppID: String { didSet { defaults.set(optimizedAppID, forKey: "dictation.optimizedAppID") } }
    var optimizedDeviceID: String { didSet { defaults.set(optimizedDeviceID, forKey: "dictation.optimizedDeviceID") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let chatterflyID = defaults.string(forKey: "dictation.chatterflyDeviceID") ?? UUID().uuidString
        chatterflyDeviceID = chatterflyID
        defaults.set(chatterflyID, forKey: "dictation.chatterflyDeviceID")
        engine = defaults.string(forKey: "dictation.engine") ?? RecognizerChoice.appleSpeech.rawValue
        language = defaults.string(forKey: "dictation.language") ?? "zh-CN"
        liveInsertion = defaults.object(forKey: "dictation.liveInsertion") as? Bool ?? true
        finalCorrection = defaults.bool(forKey: "dictation.finalCorrection")
        holdWithFn = defaults.bool(forKey: "dictation.holdWithFn")
        nearInput = defaults.object(forKey: "dictation.nearInput") as? Bool ?? true
        compatiblePaste = defaults.object(forKey: "dictation.compatiblePaste") as? Bool ?? true
        refinementBaseURL = defaults.string(forKey: "dictation.refinementBaseURL") ?? ""
        refinementModel = defaults.string(forKey: "dictation.refinementModel") ?? ""
        replacements = defaults.string(forKey: "dictation.replacements") ?? ""
        func configured(_ key: String, fallback: String?) -> String {
            let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? fallback ?? "" : stored
        }
        let profile = OptimizedDictationDefaults.bundled
        optimizedURL = configured("dictation.optimizedURL", fallback: profile?.url)
        optimizedAppID = configured("dictation.optimizedAppID", fallback: profile?.appID)
        optimizedDeviceID = configured("dictation.optimizedDeviceID", fallback: profile?.deviceID)
    }

    var engineLabel: String {
        if engine == Self.chatterflyEngine { return "Chatterfly" }
        return engine == Self.optimizedEngine ? "豆包输入法引擎" : RecognizerChoice(rawValue: engine)?.label ?? "请选择引擎"
    }

    var languageLabel: String {
        if language == "zh-Hans" { return "简体中文" }
        if language == "zh-Hant" { return "繁體中文" }
        return DictationLanguage(rawValue: language)?.title ?? language
    }

    var rules: [VocabularyTerm] {
        GlossaryEntry.parse(replacements.components(separatedBy: .newlines)).map { .init(source: $0.source, target: $0.target) }
    }
}

struct DictationConfiguration {
    var recognizer: any SpeechRecognizer
    var language: String?
    var vocabulary: [String]
    var replacements: [VocabularyTerm]
    var corrector: DictationCorrector?
    var microphoneID: String?
    var liveInsertion: Bool
}
