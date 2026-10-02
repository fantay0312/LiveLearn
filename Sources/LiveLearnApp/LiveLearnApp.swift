import SwiftUI
import AppKit
import MacAudio

@main
struct LiveLearnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LiveLearn", id: "main") {
            AdaptiveInterface(preference: delegate.settings.interfaceSize) {
                ThemedRoot(settings: delegate.settings) {
                    if delegate.settings.onboardingCompleted { RootView() }
                    else { OnboardingView() }
                }
            }
                .environment(delegate.model)
                .onAppear { delegate.model.mainWindowVisible = true }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: LLMetrics.defaultWindow.width, height: LLMetrics.defaultWindow.height)
        .commands {
            TranslationCommands(model: delegate.model)
            CommandMenu("语音输入") {
                if delegate.settings.modules.isEnabled(.dictation) {
                Button(delegate.model.dictation.phase == .listening ? "完成语音输入" : "开始语音输入") {
                    if delegate.model.dictation.isActive { delegate.model.dictation.toggle() }
                    else { delegate.model.dictation.startFromInterface() }
                }
                    .keyboardShortcut(delegate.settings.hotKey(for: .toggleDictation)?.keyboardShortcut)
                Button("取消语音输入") { delegate.model.dictation.cancel() }
                    .disabled(delegate.model.dictation.phase == .idle && !delegate.model.dictation.isActive)
                Button("复制听写结果") { delegate.model.dictation.copyResult() }
                    .disabled(delegate.model.dictation.text.isEmpty)
                Divider()
                Menu("语言") {
                    Picker("听写语言", selection: Binding(get: { delegate.settings.dictation.language }, set: { delegate.settings.dictation.language = $0 })) {
                        ForEach(DictationLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
                    }
                }
                Menu("LLM 纠错") {
                    Toggle("启用完成纠错", isOn: Binding(get: { delegate.settings.dictation.finalCorrection }, set: { delegate.settings.dictation.finalCorrection = $0 }))
                    Button("纠错设置…") {
                        delegate.settings.requestedSettingsTab = .dictation
                        UnifiedSettingsPresentation.shared.open()
                    }
                }
                Button("语音输入设置…") {
                    delegate.settings.requestedSettingsTab = .dictation
                    UnifiedSettingsPresentation.shared.open()
                }
                } else {
                    Button("添加语音输入…") {
                        delegate.settings.requestedSettingsTab = .dictation
                        UnifiedSettingsPresentation.shared.open()
                    }
                }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { UnifiedSettingsPresentation.shared.open() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("词汇库…") { delegate.model.requestVocabularyWindow() }
            }
            CommandMenu("会话") {
                Button("开始") { delegate.model.start() }
                    .disabled(!delegate.model.canStart)
                Button(delegate.model.sessionState == .paused ? "继续" : "暂停") { delegate.model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!delegate.model.canPauseOrResume)
                Button("停止") { delegate.model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!delegate.model.canStop)
                Divider()
                Button(delegate.model.overlayVisible ? "隐藏字幕" : "显示字幕") { delegate.model.toggleOverlay() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                // The lock item shows the configured global shortcut (设置 › 快捷键); Carbon
                // consumes that chord system-wide, so the menu never fires it a second time.
                Button(delegate.model.overlayLocked ? "解锁浮层" : "锁定浮层") { delegate.model.toggleLock() }
                    .keyboardShortcut(delegate.settings.hotKey(for: .toggleLock)?.keyboardShortcut)
                Divider()
                Button("快捷键…") {
                    // Opened from here directly: no mounted view is needed for the request.
                    if delegate.settings.requestedSettingsTab != .shortcuts { delegate.settings.requestedSettingsTab = .shortcuts }
                    UnifiedSettingsPresentation.shared.open()
                }
            }
        }


        Window("LiveLearn 音源检查", id: "source-check") {
            ThemedRoot(settings: delegate.settings) { SourceCheckView() }
                .environment(delegate.model)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            ThemedRoot(settings: delegate.settings) { MenuBarView() }
                .environment(delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item's nucleus changes from a dot to a star for an active session; no red dot.
/// It is mounted for the app's whole life, so it is also where a request to reopen the main
/// window is answered when no window exists to bring forward.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: model.isActive ? LLBrandAssets.menuBarActive : LLBrandAssets.menuBarIdle)
            .accessibilityLabel("LiveLearn")
            .accessibilityValue(model.statusText)
            .onChange(of: model.openSettingsRequest) { _, _ in
                UnifiedSettingsPresentation.shared.open()
            }
            .onChange(of: model.openMainWindowRequest) { _, _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onChange(of: model.openSourceCheckRequest) { _, _ in
                openWindow(id: "source-check")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // UI regression runs use an isolated preferences domain; normal launches use the user's
    // real settings. This only redirects preferences, never the recognition pipeline.
    let settings: AppSettings = {
        let args = CommandLine.arguments
        if args.contains("--probe-caption-backdrop-access") {
            print("caption backdrop access: \(CaptionBackdropSampler.hasAccess)")
            exit(0)
        }
        if let i = args.firstIndex(of: "--preferences-suite"), i + 1 < args.count,
           args[i + 1].hasPrefix("LiveLearn.testing."), let defaults = UserDefaults(suiteName: args[i + 1]) {
            return AppSettings(defaults: defaults)
        }
        return AppSettings()
    }()
    lazy var model = AppModel(settings: settings)
    private var overlay: OverlayPanelController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-onboarding"), i + 1 < args.count {
            do { try PreviewRenderer.renderOnboarding(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Onboarding preview failed: \(error)"); exit(1) }
            exit(0)
        }
        if args.contains("--caption-reading-layout") {
            settings.showPreviousLine = true
            settings.showSourceInOverlay = true
        }
        if let i = args.firstIndex(of: "--render-settings-modes"), i + 1 < args.count {
            do { try PreviewRenderer.renderSettingsModes(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Settings mode previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-source-configuration"), i + 1 < args.count {
            do { try PreviewRenderer.renderSourceConfiguration(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Source configuration previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-browser-extension"), i + 1 < args.count {
            do { try PreviewRenderer.renderBrowserExtension(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Browser extension previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-unified-nebula"), i + 1 < args.count {
            do { try PreviewRenderer.renderUnifiedNebula(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Unified nebula previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-settings-feedback"), i + 1 < args.count {
            do { try PreviewRenderer.renderSettingsFeedback(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Settings feedback previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-dock-feedback"), i + 1 < args.count {
            do { try PreviewRenderer.renderDockFeedback(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Dock feedback previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-navigation-stars"), i + 1 < args.count {
            do { try PreviewRenderer.renderNavigationStars(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Navigation star previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-active-stardust"), i + 1 < args.count {
            do { try PreviewRenderer.renderStardust(to: URL(fileURLWithPath: args[i + 1]), activity: 1) }
            catch { print("Active stardust previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-stardust"), i + 1 < args.count {
            do { try PreviewRenderer.renderStardust(to: URL(fileURLWithPath: args[i + 1])) }
            catch { print("Stardust previews failed: \(error)"); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-ambient-parity"), i + 1 < args.count {
            // The Canvas and the Metal frame of the same instant for the Home particle layers,
            // written side by side for a pixel comparison of the two rendering paths. An
            // optional comma list of backing scales follows the directory (default 1,2).
            let scales: [CGFloat] = i + 2 < args.count ? args[i + 2].split(separator: ",").compactMap { Double($0).map { CGFloat($0) } } : []
            do { try AmbientParityRenderer.render(to: URL(fileURLWithPath: args[i + 1], isDirectory: true),
                                                  scales: scales.isEmpty ? AmbientParityRenderer.defaultScales : scales) }
            catch { FileHandle.standardError.write(Data("Ambient parity render failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-membrane"), i + 1 < args.count {
            do { try PreviewRenderer.renderMembrane(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Membrane preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-breathing-transport"), i + 1 < args.count {
            do { try PreviewRenderer.renderBreathingTransport(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Transport preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-living-controls"), i + 1 < args.count {
            do { try PreviewRenderer.renderLivingControls(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Control preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-starmap-previews"), i + 1 < args.count {
            do { try PreviewRenderer.renderStarMap(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Star map preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-exploration-previews"), i + 1 < args.count {
            do { try PreviewRenderer.renderExplorationThemes(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Theme preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-main-previews"), i + 1 < args.count {
            do { try PreviewRenderer.renderMainLayout(to: URL(fileURLWithPath: args[i + 1], isDirectory: true)) }
            catch { FileHandle.standardError.write(Data("Main preview failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-overlay-previews"), i + 1 < args.count {
            do {
                try PreviewRenderer.renderReadability(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("overlay preview failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
            let target = args[i + 1]
            let seconds = i + 2 < args.count ? Int(args[i + 2]) ?? 5 : 5
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let code: Int32
                if target.hasPrefix("dictation:") {
                    code = await DictationProbe.run(spec: target)
                } else if target.hasPrefix("engine:") {
                    code = await EngineProbe.run(spec: target)
                } else if target.hasPrefix("whisper:") {
                    code = await WhisperProbe.run(spec: target)
                } else {
                    code = await AudioProbe.run(target: target, seconds: seconds)
                }
                exit(code)
            }
            return
        }
        if let i = args.firstIndex(of: "--render-previews"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            do {
                try PreviewRenderer.renderAll(to: dir)
                print("previews written to \(dir.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("preview render failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ModuleLibrary.shared = settings.modules
        UnifiedSettingsPresentation.shared.configure(settings: settings) { [weak self] in
            self?.model.requestMainWindow()
        }
        TranslationFeature.shared.onVocabularyDraft = { [weak self] draft in
            self?.model.translationVocabularyDraft = draft
            self?.model.requestVocabularyWindow()
        }
        TranslationFeature.shared.resumeIfEnabled()
        #if DEBUG
        if CommandLine.arguments.contains("--trace-vocabulary-window") { VocabularyWindowTrace.install() }
        #endif
        let overlay = OverlayPanelController(model: model)
        overlay.install()
        self.overlay = overlay
        HotKeyCenter.shared.handler = { [weak self] action in
            self?.perform(hotKey: action)
        }
        HotKeyCenter.shared.releaseHandler = { [weak self] action in
            if action == .holdDictation { self?.model.dictation.endHolding(source: "custom") }
        }
        HotKeyCenter.shared.cancellationHandler = { [weak self] action in
            if action == .holdDictation { self?.model.dictation.cancel() }
        }
        observeHotKeys()
        // Development flags:
        //   --open-settings <page>           open the settings modal on that page (LiveLearnSettingsPage raw
        //                                    value, e.g. sources / appearance / theme) once the window is up,
        //                                    so a settings state can be measured or captured without driving the UI
        //   --autostart <targets>            comma list of mic | system | app:<bundle id> | file:<audio path>;
        //                                    several app: entries are ticked together (one mixed channel);
        //                                    starts after launch (file: feeds the 系统声 lane from a file, no consent dialog)
        //   --autostop <seconds>             stop the auto-started session after N seconds, then quit
        //   --ambient-renderer canvas|metal  the path the Home particle layers (stars, dust, core, and the
        //                                    wordmark, navigation stars, nebula selections and action-button
        //                                    light) draw with; metal when a GPU is available unless the flag
        //                                    says canvas (read by `AmbientRendering.preferred`)
        //   --ambient-time <seconds>         pin every ambient clock — each LuminousMotion and each Metal
        //                                    display link — to one instant that never advances, so a Canvas
        //                                    frame and a Metal frame of the same moment can be captured and
        //                                    compared (read by `AmbientRendering.pinnedTime`)
        //   --ambient-layers <a,b,…>         mount only the named Metal layers (sky, core, wordmark, nav, nebula,
        //                                    button; "none" for none); every other surface falls back to its
        //                                    Canvas branch. Measurement only — the product mounts them all
        //                                    (read by `AmbientRendering.enabledLayers`)
        //   --ambient-probe ticks-only|no-links
        //                                    ticks-only: every Metal host keeps its display link ticking but
        //                                    builds and presents nothing; no-links: no host starts a link at
        //                                    all and every layer holds its first frame. Together they separate
        //                                    the cost of the links from the cost of the presents. Measurement
        //                                    only (read by `AmbientRendering.ticksOnly` / `.noLinks`)
        //   --trace-ambient                log gate/driver state and bounded frame counters
        //   --render-ambient-parity <dir> [scales]
        //                                    (handled in applicationWillFinishLaunching, like the other --render-*
        //                                    flags) write the Canvas frame and the Metal frame of one instant for
        //                                    the sky, the core and the four small surfaces (wordmark, navigation
        //                                    stars, nebula halo, action-button light), for a pixel comparison;
        //                                    at every backing scale in the optional comma list (default 1,2)
        //   --capture-window <png> [--capture-delay <seconds>]
        //                                    write the main window as the window server composites it (Metal
        //                                    layers and the modal blur included) after the delay (default 4 s),
        //                                    then quit; the process images its own window, so no screen
        //                                    recording permission is involved
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--capture-window"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let delay = args.firstIndex(of: "--capture-delay").flatMap { j in j + 1 < args.count ? Double(args[j + 1]) : nil } ?? 4
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, delay)))
                let written = WindowCapture.write(WindowCapture.target, to: url)
                if !written { FileHandle.standardError.write(Data("window capture failed\n".utf8)) }
                exit(written ? 0 : 1)
            }
        }
        if let i = args.firstIndex(of: "--capture-caption"), i + 1 < args.count {
            let directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            Task { @MainActor in
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for second in [6, 12, 18, 24] {
                    try? await Task.sleep(for: .seconds(6))
                    let written = self.overlay?.capture(to: directory.appendingPathComponent("caption-\(second)s.png")) ?? false
                    print("caption capture \(second)s: \(written)")
                    if second == 18 {
                        _ = await self.overlay?.captureBackdrop(.white, to: directory.appendingPathComponent("caption-white.png"))
                        _ = await self.overlay?.captureBackdrop(NSColor(white: 0.08, alpha: 1), to: directory.appendingPathComponent("caption-dark.png"))
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--open-settings"), i + 1 < args.count {
            let page = LiveLearnSettingsPage(rawValue: args[i + 1]) ?? .sources
            settings.requestedSettingsTab = page.settingsTab
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                UnifiedSettingsPresentation.shared.open()
            }
        }
        if let i = args.firstIndex(of: "--autostart"), i + 1 < args.count {
            let targets = args[i + 1].split(separator: ",").map(String.init)
            let model = self.model
            model.useMicrophone = false
            model.useApplication = false
            model.useSystem = false
            var apps: [RunningApplicationSummary] = []
            for target in targets {
                switch target {
                case "mic": model.useMicrophone = true
                case "system": model.useSystem = true
                default:
                    if target.hasPrefix("file:") {
                        model.useSystem = true
                        model.captureFileOverride = URL(fileURLWithPath: String(target.dropFirst(5)))
                    } else if target.hasPrefix("app:") {
                        let bid = String(target.dropFirst(4))
                        if let app = model.applications.first(where: { $0.bundleIdentifier == bid }) { apps.append(app) }
                    }
                }
            }
            if !apps.isEmpty { model.select(applications: apps) }
            let stopAfter: Int? = args.firstIndex(of: "--autostop").flatMap { j in j + 1 < args.count ? Int(args[j + 1]) : nil }
            Task { @MainActor in
                // Let the readiness check for the local engine land before the start gate runs.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                model.start()
                guard let stopAfter else { return }
                try? await Task.sleep(nanoseconds: UInt64(stopAfter) * 1_000_000_000)
                model.stop()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: Global shortcuts (§9.4 快捷键)

    /// Registers the configured table and follows it: a change on the settings page re-runs
    /// this through Observation, the same way the model follows its engine settings.
    private func observeHotKeys() {
        withObservationTracking {
            applyAvailableHotKeys()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKeys() }
        }
    }

    private func applyAvailableHotKeys() {
        let enabled = settings.modules.isEnabled(.dictation)
        if enabled { model.dictation.install() }
        HotKeyCenter.shared.apply(settings.hotKeyBindings.filter { enabled || ![.toggleDictation, .cancelDictation, .holdDictation].contains($0.key) })
    }

    /// The overlay is the feedback for every one of these: it appears when a session starts,
    /// says 已暂停 / 已结束, and shows the lock. Only a start that cannot happen has nothing to
    /// show, so that one brings the window forward with its explanation.
    func perform(hotKey action: HotKeyAction) {
        switch action {
        case .toggleSession:
            if model.isActive {
                model.stop()
            } else if model.canStart {
                model.start()
            } else {
                showMainWindow()
            }
        case .togglePause:
            if model.isActive { model.togglePause() }
        case .toggleOverlay:
            // Captions exist only during a session (or just after one); with nothing to show,
            // the window comes forward and says 未开始 instead of the key doing nothing.
            if (model.isActive || model.sessionState == .completed) && !model.isViewingRecord {
                model.toggleOverlay()
            } else {
                showMainWindow()
            }
        case .toggleLock:
            model.toggleLock()
        case .showMainWindow:
            showMainWindow()
        case .toggleDictation:
            model.dictation.toggle()
        case .cancelDictation:
            model.dictation.cancel()
        case .holdDictation:
            model.dictation.beginHolding(source: "custom")
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// Brings the main window forward. When it was closed (the app kept running in the menu
    /// bar) there is nothing to order front, so the model asks the always-mounted menu bar
    /// label to open the window group again; a reopen event would do nothing while any other
    /// window (Settings, the overlay) is visible.
    func showMainWindow() {
        if let window = mainWindow {
            // makeKeyAndOrderFront leaves a minimized window in the Dock; bring it back first.
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        model.requestMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !settings.keepRunningWhenWindowCloses
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true {
                w.makeKeyAndOrderFront(nil)
            }
        } else if mainWindow == nil {
            // A Dock click with only Settings (or the overlay) open: bring the main window back.
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.dictation.shutdown()
        TranslationFeature.shared.shutdown()
        HotKeyCenter.shared.unregisterAll()
        if model.isActive {
            // Stop is asynchronous and may not finish before exit; the checkpoint (auto-save on)
            // guarantees the transcript so far comes back as an "interrupted" record.
            model.writeCheckpoint()
            model.stop()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        applyAvailableHotKeys()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let text = TranslationDeepLink.text(from: url) {
                TranslationFeature.shared.perform("query", text: text)
            }
        }
    }
}
