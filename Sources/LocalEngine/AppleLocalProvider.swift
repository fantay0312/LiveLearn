import Foundation
import ProviderAdapters
import EngineKit

/// The on-device engine: Apple `SpeechAnalyzer` (macOS 26) → `SpeechSegmenter` → Apple
/// `Translation`, as one `PipelineProvider`. Nothing leaves the machine. Kept as a named
/// constructor so callers that only want "the Apple pair" do not have to know the stages.
@available(macOS 26, *)
public enum AppleLocalProvider {
    public static let providerID = "apple.local"

    public static func make(translatesPartials: Bool = true) -> PipelineProvider {
        PipelineProvider(recognizer: AppleSpeechRecognizer(), translator: AppleTextTranslator(), providerID: providerID, displayName: "本机引擎", translatesPartials: translatesPartials)
    }
}
