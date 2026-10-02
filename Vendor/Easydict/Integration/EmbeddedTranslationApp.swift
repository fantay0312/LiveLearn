// LiveLearn adaptation of Easydict, GPL-3.0. See the bundled source and LICENSE.
// Commands use private inherited pipes, never a network listener or shared command file.
import AppKit
import Defaults
import Foundation
import SwiftUI

@main
struct LiveLearnTranslationApp: App {
    @NSApplicationDelegateAdaptor(LiveLearnTranslationDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                EasydictMainMenu.MainMenuShortcutCommand()
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { EmbeddedTranslationRuntime.shared.showSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appSettings) {
                    Button("加入 LiveLearn 词汇…") { EmbeddedTranslationRuntime.shared.sendVocabularyDraft() }
                        .keyboardShortcut("b", modifiers: [.command, .shift])
                }
                CommandGroup(replacing: .appInfo) {
                    Button("关于 LiveLearn 翻译") { EmbeddedTranslationRuntime.shared.showSettings(.about) }
                }
            }
    }
}

final class LiveLearnTranslationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        EmbeddedTranslationRuntime.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        FileHandle.standardInput.readabilityHandler = nil
        EventMonitor.shared.stop()
    }
}

/// The single owner of helper lifetime, settings windows and the host command stream.
@MainActor
final class EmbeddedTranslationRuntime: NSObject {
    static let shared = EmbeddedTranslationRuntime()
    private var buffer = Data()
    private var preferencesSnapshot: NSDictionary = [:]
    private var observer: NSObjectProtocol?
    private var parentWatch: Timer?
    private let maxMessageBytes = 1_048_576

    func start() {
        guard CommandLine.arguments.contains("--livelearn-embedded") else {
            // A nested helper is a feature of its containing app, not a second launcher.
            var directory = Bundle.main.bundleURL.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidates = [directory, directory.appendingPathComponent("LiveLearn.app")]
                if let host = candidates.first(where: { Bundle(url: $0)?.bundleIdentifier == "com.fantasy.livelearn" }) {
                    NSWorkspace.shared.openApplication(at: host, configuration: .init())
                    break
                }
                directory.deleteLastPathComponent()
            }
            NSApp.terminate(nil)
            return
        }
        if Defaults[.firstLaunch] {
            Defaults[.firstLaunch] = false
            Defaults[.hideMainWindow] = true
            Defaults[.allowCrashLog] = false
            Defaults[.allowAnalytics] = false
            ShortcutManager.shared.setDefaultAppShortcutKeys()
        }
        preferencesSnapshot = currentPreferences()
        ShortcutManager.shared.setupShortcut()
        DarkModeManager.shared.updateDarkMode(MyConfiguration.shared.appearance)
        observer = NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.showSettings() }
        }
        FileHandle.standardInput.readabilityHandler = { handle in
            let data = handle.availableData
            DispatchQueue.main.async { Self.shared.receive(data) }
        }
        parentWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if getppid() == 1 { NSApp.terminate(nil) }
        }
        reply(["event": "ready", "ok": true, "protocolVersion": 1,
               "services": QueryServiceFactory.shared.allServiceTypeIDs,
               "languages": EZLanguageManager.shared().allLanguages.count])
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { NSApp.terminate(nil); return }
        buffer.append(data)
        guard buffer.count <= maxMessageBytes else { buffer.removeAll(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? String,
                  let action = message["action"] as? String else { continue }
            perform(action, id: id, message: message)
        }
    }

    private func perform(_ action: String, id: String, message: [String: Any]) {
        switch action {
        case "status":
            reply(["id": id, "ok": true, "services": QueryServiceFactory.shared.allServiceTypeIDs,
                   "languages": EZLanguageManager.shared().allLanguages.count,
                   "windows": NSApp.windows.filter(\.isVisible).map(\.title),
                   "settingsClearInput": MyConfiguration.shared.clearInput])
        case "theme":
            reply(["id": id, "ok": true])
        case "workbench":
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            let manager = EZWindowManager.shared()
            manager.inputTranslate {
                if let window = manager.floatingWindow, window.isVisible, let screen {
                    let frame = screen.visibleFrame
                    window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                                  y: frame.midY - window.frame.height / 2))
                }
            }
            reply(["id": id, "ok": true])
        case "query":
            EZWindowManager.shared().showFloating(MyConfiguration.shared.shortcutSelectTranslateWindowType,
                queryText: message["text"] as? String, autoQuery: true, actionType: .invokeQuery)
            reply(["id": id, "ok": true])
        case "settings":
            showSettings((message["settingsSection"] as? Int).flatMap(SettingTab.init(rawValue:)))
            reply(["id": id, "ok": true])
        case "settings.reload":
            reloadPreferences()
            reply(["id": id, "ok": true])
        case "settings.recording":
            MyConfiguration.shared.isRecordingSelectTextShortcutKey = message["text"] as? String == "true"
            reply(["id": id, "ok": true])
        case "favorites":
            showSettings(.favorites)
            reply(["id": id, "ok": true])
        case "image":
            guard let path = message["text"] as? String, let image = NSImage(contentsOfFile: path) else {
                reply(["id": id, "ok": false, "error": "无法读取所选图片。"])
                return
            }
            EZWindowManager.shared().showFloatingWindow(withOCRImage: image, autoQuery: true, actionType: .invokeQuery)
            reply(["id": id, "ok": true])
        case "snapshot":
            let controller = EZWindowManager.shared().floatingWindow?.queryViewController
            reply(["id": id, "ok": true,
                   "source": controller?.inputText ?? "",
                   "translation": completedResult()?.translation ?? "",
                   "historyCount": Defaults[.queryHistory].count])
        case "result":
            guard let result = completedResult() else {
                reply(["id": id, "ok": false, "error": "当前窗口还没有完成的译文。"])
                return
            }
            reply(["id": id, "ok": true, "source": result.source, "translation": result.translation])
        case "shutdown":
            reply(["id": id, "ok": true])
            NSApp.terminate(nil)
        default:
            guard let shortcut = ShortcutAction(rawValue: action) else {
                reply(["id": id, "ok": false, "error": "不支持的翻译操作。"])
                return
            }
            Task { @MainActor in
                if ["selectTranslate", "translateAndReplace", "polishAndReplace"].contains(action),
                   let pid = message["targetPID"] as? Int32,
                   let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated {
                    target.activate(options: [.activateIgnoringOtherApps])
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await shortcut.configuration.action()
                self.reply(["id": id, "ok": true])
            }
        }
    }

    func showSettings(_ selection: SettingTab? = nil) {
        yieldToHost()
        var event: [String: Any] = ["event": "settingsNavigation", "ok": true,
                                  "settingsPage": LiveLearnSettingsPage.textTranslation.rawValue]
        if let selection { event["settingsSection"] = selection.rawValue }
        reply(event)
    }

    private func yieldToHost() {
        if #available(macOS 14.0, *), let host = NSRunningApplication(processIdentifier: getppid()) {
            NSApp.yieldActivation(to: host)
        }
    }

    private func currentPreferences() -> NSDictionary {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]) as NSDictionary
    }

    private func reloadPreferences() {
        let defaults = UserDefaults.standard
        defaults.synchronize()
        let latest = currentPreferences()
        let keys = Set(preferencesSnapshot.allKeys.compactMap { $0 as? String })
            .union(latest.allKeys.compactMap { $0 as? String })
        for key in keys where (preferencesSnapshot[key] as? NSObject) != (latest[key] as? NSObject) {
            defaults.willChangeValue(forKey: key)
            defaults.didChangeValue(forKey: key)
        }
        preferencesSnapshot = latest
        ShortcutManager.shared.setupGlobalShortcutActions()
        GlobalContext.shared.reloadLLMServicesSubscribers()
        NotificationCenter.default.postServiceUpdateNotification()
        for name: Notification.Name in [.didChangeFontSize, .didChangeWindowConfiguration, .maxWindowHeightSettingsChanged, .linkButtonUpdated, .languagePreferenceChanged] {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }

    func sendVocabularyDraft() {
        guard let result = completedResult() else {
            EZToast.showText("请先完成当前文字的翻译，再加入词汇。")
            return
        }
        reply(["event": "vocabulary", "ok": true, "source": result.source, "translation": result.translation])
    }

    private func completedResult() -> (source: String, translation: String)? {
        guard let controller = EZWindowManager.shared().floatingWindow?.queryViewController else { return nil }
        for service in controller.services {
            guard let result = service.result, !result.isLoading, result.isStreamFinished, result.error == nil,
                  result.queryText == controller.queryModel.queryText,
                  let text = result.translatedText ?? result.copiedText, !text.isEmpty else { continue }
            return (result.queryText, text)
        }
        return nil
    }

    private func reply(_ response: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let token = ProcessInfo.processInfo.environment["LIVELEARN_TRANSLATION_CHANNEL"] ?? ""
        FileHandle.standardOutput.write(Data(("LIVELEARN_TRANSLATION:" + token + ":" + line + "\n").utf8))
    }
}

enum MenuBarIconType: String, CaseIterable, Defaults.Serializable, Identifiable {
    case square = "square_menu_bar_icon"
    case rounded = "rounded_menu_bar_icon"
    var id: Self { self }
}

extension Bool {
    var toggledValue: Bool {
        get { !self }
        mutating set { self = !newValue }
    }
}
