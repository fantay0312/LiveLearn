import Foundation
import AVFoundation
import CaptionDomain
import MacAudio

/// Speaks finalized translations with the system voice for the target language. Finals only,
/// one sentence at a time; when the speaker falls behind, the oldest unspoken sentences are
/// dropped and the voice speeds up a little, so it never trails the captions by more than a
/// few sentences. While it speaks, the microphone is muted (`MicrophoneGate`) so the room's
/// loudspeaker does not get transcribed.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [(text: String, language: String)] = []
    private var speaking = false
    /// Sentences allowed to wait; beyond this the oldest are dropped.
    var maxQueued = 3

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, language: String) {
        pending.append((text, language))
        if pending.count > maxQueued { pending.removeFirst(pending.count - maxQueued) }
        if !speaking { next() }
    }

    func stop() {
        pending = []
        if speaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
        MicrophoneGate.shared.isMuted = false
    }

    private func next() {
        guard !pending.isEmpty else {
            speaking = false
            MicrophoneGate.shared.isMuted = false
            return
        }
        let item = pending.removeFirst()
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.voice = Self.voice(for: item.language)
        // Catch up gently: a little faster for every sentence still waiting, capped.
        utterance.rate = min(AVSpeechUtteranceDefaultSpeechRate + 0.04 * Float(pending.count), AVSpeechUtteranceDefaultSpeechRate + 0.12)
        speaking = true
        MicrophoneGate.shared.isMuted = true
        synthesizer.speak(utterance)
    }

    /// The system voice for a catalog code: `zh-Hans` → zh-CN, `zh-Hant` → zh-TW, `yue` → zh-HK.
    static func voice(for code: String) -> AVSpeechSynthesisVoice? {
        let bcp47: String
        switch LanguageCatalog.canonical(code) {
        case "zh-Hans": bcp47 = "zh-CN"
        case "zh-Hant": bcp47 = "zh-TW"
        case "yue": bcp47 = "zh-HK"
        case "en": bcp47 = "en-US"
        case "pt-BR": bcp47 = "pt-BR"
        case "pt-PT": bcp47 = "pt-PT"
        case let other: bcp47 = other
        }
        return AVSpeechSynthesisVoice(language: bcp47) ?? AVSpeechSynthesisVoice(language: String(bcp47.prefix(2)))
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.next() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.next() }
    }
}
