import Foundation
import LocalEngine
import Observation

/// Operations outlive a settings page. Returning to the page keeps progress and prevents
/// a second download/test from being launched while the original task is still running.
@MainActor @Observable
final class LocalModelActivity {
    var speechStates: [String: AssetState] = [:]
    var translationStates: [String: AssetState] = [:]
    var speechProgress: [String: Double] = [:]
    var notes: [String: String] = [:]
    var refreshing = false
    var whisperInstalled: [String: Int64] = [:]
    var whisperProgress: [String: Double] = [:]
    var whisperPreparing: Set<String> = []
    var whisperNotes: [String: String] = [:]
}

@MainActor @Observable
final class TranslationTestActivity {
    var running = false
    var result = ""
    var configuration = ""
    var failed = false
}
