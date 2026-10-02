import Foundation
import Testing
import SessionStorage
@testable import LiveLearnApp

@MainActor
struct OverlayCloseTests {
    @Test func closePolicyIsOptInAndRemembersTheSelectedAction() {
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.controlSessionOnOverlayClose && settings.overlayCloseAction == .endSession)
        settings.controlSessionOnOverlayClose = true
        settings.overlayCloseAction = .pause
        settings.controlSessionOnOverlayClose = false
        let restored = AppSettings(defaults: defaults)
        #expect(!restored.controlSessionOnOverlayClose && restored.overlayCloseAction == .pause)
        restored.controlSessionOnOverlayClose = true
        restored.resetOverlayStyle()
        #expect(restored.controlSessionOnOverlayClose && restored.overlayCloseAction == .pause)
        defaults.set("unknown-action", forKey: "overlayCloseAction")
        #expect(AppSettings(defaults: defaults).overlayCloseAction == .endSession)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"] != nil))
    func hideActionsPauseAndEndTheRealSessionWithoutAutomaticResume() async throws {
        let audio = try #require(ProcessInfo.processInfo.environment["LIVELEARN_OVERLAY_AUDIO"])
        let suite = "LiveLearn.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, store: SessionStore(directory: folder), credentials: .empty)
        model.captureFileOverride = URL(fileURLWithPath: audio)
        try #require(await model.blueprint.readiness(source: "en", target: "zh-Hans").isReady)
        model.start()
        defer { model.stop() }
        let deadline = Date().addingTimeInterval(15)
        while (model.captions.segments.isEmpty || !model.isRunning) && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(model.isRunning && !model.captions.segments.isEmpty)
        let originalID = model.sessionID
        model.hideOverlay()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isRunning)
        settings.controlSessionOnOverlayClose = true
        settings.overlayCloseAction = .pause
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isRunning, "Changing the preference while already hidden is not another close action.")
        model.toggleOverlay()
        model.toggleOverlay()
        let pauseDeadline = Date().addingTimeInterval(3)
        while (model.sessionState != .paused || model.lanes.contains(where: \.isUploading)) && Date() < pauseDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.sessionState == .paused && model.lanes.allSatisfy { !$0.isUploading })
        settings.overlayCloseAction = .endSession
        model.hideOverlay()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sessionState == .paused, "Repeated writes of false must not dispatch a second close action.")
        model.toggleOverlay()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.sessionState == .paused, "Showing the overlay must not restart listening.")
        model.resume()
        let resumeDeadline = Date().addingTimeInterval(3)
        while !model.isRunning && Date() < resumeDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(model.isRunning)
        model.overlayVisible = false // Same path as the main window's SwiftUI toggle binding.
        let stopDeadline = Date().addingTimeInterval(8)
        while model.isActive && Date() < stopDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.sessionState == .completed && !model.overlayVisible)
        #expect(model.lanes.allSatisfy { !$0.isUploading && $0.capture.state == .stopped })
        #expect(model.records.contains { $0.id == originalID && $0.archive.segmentCount > 0 })
    }
}
