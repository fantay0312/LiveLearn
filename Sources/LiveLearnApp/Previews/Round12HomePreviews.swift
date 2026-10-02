import SwiftUI
import SessionDomain

/// Home's recovery states for `--render-main-previews`: a failed session, a running session with
/// advice and a start blocker. All but one are at the minimum window, where the air under
/// Home's unit (`HomeComposition.growthAir`) is tightest — the banner's line with its action
/// must stay above the dock there.
@MainActor
enum Round12HomePreviews {
    /// `model` builds a model over a snapshot, with the main previews' records; `capture` writes
    /// a view in a theme at a window size under a file name.
    static func renderRecoveryStates(settings: AppSettings, model: (SessionSnapshot) -> AppModel,
                                     capture: (AnyView, LLTheme, CGSize, String) throws -> Void) throws {
        var failed = SessionSnapshot.empty()
        failed.state = .failed
        failed.failure = "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。"
        try capture(AnyView(RootView().environment(model(failed))), .dark, LLMetrics.defaultWindow, "home-failed-dark")

        // The tightest failure: two routes and the cloud engine's cost note under the unit.
        let recognizer = settings.recognizer
        settings.recognizer = .deepgram
        let converse = model(failed)
        converse.applyMode(.converse)
        try capture(AnyView(RootView().environment(converse)), .light, LLMetrics.minWindow, "home-failed-minimum-light")
        settings.recognizer = recognizer
        converse.applyMode(.listen)

        for dual in [false, true] {
            var running = SampleData.runningSnapshot(dual: dual)
            running.lanes[0].capture.state = .permissionRequired
            try capture(AnyView(RootView().environment(model(running))), .dark, LLMetrics.minWindow,
                        "home-running-advice\(dual ? "-dual" : "")-minimum-dark")
        }

        let target = settings.listenTargetLanguage
        settings.listenTargetLanguage = settings.listenSourceLanguage
        try capture(AnyView(RootView().environment(model(.empty()))), .dark, LLMetrics.minWindow, "home-blocker-minimum-dark")
        settings.listenTargetLanguage = target
    }
}
