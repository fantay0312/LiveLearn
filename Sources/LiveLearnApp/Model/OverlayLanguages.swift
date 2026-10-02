import Foundation
import CaptionDomain

/// A local draft: opening a language picker never changes the running provider or preferences.
struct OverlayLanguages: Equatable {
    var listenSource: String
    var listenTarget: String
    var micSource: String
    var micTarget: String

    @MainActor init(settings: AppSettings) {
        listenSource = settings.listenSourceLanguage
        listenTarget = settings.listenTargetLanguage
        micSource = settings.micSourceLanguage
        micTarget = settings.micTargetLanguage
    }

    func directions(computer: Bool, microphone: Bool) -> [LanguageDirection] {
        var result: [LanguageDirection] = []
        if computer { result.append(LanguageDirection(source: listenSource, target: listenTarget)) }
        if microphone { result.append(LanguageDirection(source: micSource, target: micTarget)) }
        return result
    }

    @MainActor func apply(to settings: AppSettings) {
        settings.listenSourceLanguage = listenSource
        settings.listenTargetLanguage = listenTarget
        settings.micSourceLanguage = micSource
        settings.micTargetLanguage = micTarget
    }
}
