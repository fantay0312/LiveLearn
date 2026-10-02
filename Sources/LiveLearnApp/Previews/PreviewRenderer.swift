import AppKit
import Carbon.HIToolbox
import SwiftUI
import CaptionDomain
import SessionDomain
import MacAudio
import CloudEngine
import EngineKit

/// `LiveLearn --render-previews <dir>` renders every surface to PNG so the design can be
/// reviewed without a screen recording permission. Pure SwiftUI only (no NSViewRepresentable).
@MainActor
enum PreviewRenderer {
    static func renderOnboarding(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.onboarding-preview.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        for theme in [LLTheme.stellar, .wilds] {
            for step in 0..<3 {
                for size in [LLMetrics.defaultWindow, LLMetrics.minWindow] {
                    try render(OnboardingView(previewStep: step).environment(model), theme: theme, size: size,
                               to: directory.appendingPathComponent("onboarding-\(step)-\(theme.isDark ? "dark" : "light")-\(Int(size.width)).png"))
                }
            }
        }
    }
    static func renderSettingsModes(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.settings-modes.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.recognizer = .whisperKit
        settings.whisperModel = "openai_whisper-base"
        settings.showPreviousLine = true
        settings.showSourceInOverlay = true
        let model = AppModel(settings: settings, preview: .empty())
        for theme in [LLTheme.stellar, .wilds] {
            for mode in SettingsMode.allCases {
                settings.settingsMode = mode
                settings.requestedSettingsTab = .engine
                for window in [LLMetrics.defaultWindow, LLMetrics.minWindow] {
                    let size = LiveLearnSettingsPage.modalRect(in: CGRect(origin: .zero, size: window)).size
                    let name = "settings-\(mode.rawValue)-\(theme.isDark ? "dark" : "light")-\(Int(window.width)).png"
                    try render(SettingsView().environment(model), theme: theme, size: size, to: directory.appendingPathComponent(name))
                }
            }
        }
        let live = AppModel(settings: settings, preview: SampleData.runningSnapshot(includeGap: false))
        try render(OverlayView(forcedWidth: 880).environment(live).background(Color(hex: 0x252A30)),
                   theme: .stellar, size: CGSize(width: 880, height: 360), to: directory.appendingPathComponent("captions-live.png"))
        settings.showSourceInOverlay = false
        try render(OverlayView(forcedWidth: 880).environment(live).background(Color(hex: 0x252A30)),
                   theme: .stellar, size: CGSize(width: 880, height: 300), to: directory.appendingPathComponent("captions-translation-only.png"))
        settings.showSourceInOverlay = true
        var snapshot = SampleData.runningSnapshot(includeGap: false)
        var segment = snapshot.captions.segments[0]
        segment.sourceText = "The agent is running in the harness. It reasons about the next action. It chooses a tool until the problem is solved. Then it can draw a chart."
        segment.translation?.text = "智能体正在运行。它会推理下一步操作。它会选择工具，直到问题得到解决。然后，它还可以绘制图表。"
        snapshot.captions.items = [.segment(segment)]
        let long = AppModel(settings: settings, preview: snapshot)
        try render(OverlayView(forcedWidth: 880).environment(long).background(Color(hex: 0x252A30)),
                   theme: .stellar, size: CGSize(width: 880, height: 300), to: directory.appendingPathComponent("captions-long.png"))
        segment.sourceText = String(repeating: "a long unpunctuated transcript ", count: 30) + "the newest words remain visible"
        segment.translation?.text = String(repeating: "一段没有标点的长字幕", count: 50) + "最新的内容仍然清晰可见"
        snapshot.captions.items = [.segment(segment)]
        let unpunctuated = AppModel(settings: settings, preview: snapshot)
        try render(OverlayView(forcedWidth: 600).environment(unpunctuated).background(Color(hex: 0x252A30)),
                   theme: .stellar, size: CGSize(width: 600, height: 240), to: directory.appendingPathComponent("captions-unpunctuated.png"))
    }

    static func renderSettingsFeedback(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, SettingsControlPreview, Bool)] = [
            ("idle", .init(), true), ("hover", .init(hovered: true), true),
            ("pressed", .init(hovered: true, pressed: true), true),
            ("disabled", .init(hovered: true), false),
            ("reduced", .init(hovered: true, pressed: true, reduceMotion: true), true)
        ]
        for theme in [LLTheme.stellar, .wilds] {
            for (name, state, enabled) in states {
                let view = HStack(spacing: 32) {
                    Button {} label: { Text("语言").font(.system(size: 13)).frame(width: 120, height: 32, alignment: .leading) }
                        .buttonStyle(RailRowStyle(dark: theme.isDark, anchor: .leading, preview: state))
                    HStack(spacing: 8) {
                        ForEach(["文字", "背景与布局", "显示与行为"], id: \.self) { title in
                            Button {} label: {
                                Text(title).font(.system(size: 13))
                                    .overlay(alignment: .bottom) {
                                        if title == "文字" { SettingsStarPoint(dark: theme.isDark, stamped: true) }
                                    }
                                    .padding(.horizontal, 10).frame(height: 40)
                            }
                            .buttonStyle(RailRowStyle(selected: title == "文字", dark: theme.isDark, preview: state))
                        }
                    }
                }
                .disabled(!enabled).padding(24).background(theme.ground)
                try render(view, theme: theme, size: CGSize(width: 510, height: 96),
                           to: directory.appendingPathComponent("\(theme.isDark ? "dark" : "light")-\(name).png"))
            }
        }
        let suite = "LiveLearn.testing.settings-feedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: .empty())
        for tab in [SettingsTab.appearance, .language] {
            settings.requestedSettingsTab = tab
            try render(SettingsView().environment(model), theme: .stellar, size: SettingsView.size,
                       to: directory.appendingPathComponent("page-\(tab.rawValue).png"))
        }
    }

    static func renderDockFeedback(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let states: [(String, DockInteraction, Bool, Bool)] = [
            ("idle", .init(), true, false),
            ("hover", .init(hovered: true), true, false),
            ("pressed", .init(hovered: true, pressed: true), true, false),
            ("disabled", .init(hovered: true), false, false),
            ("reduced-hover", .init(hovered: true), true, true),
            ("reduced-pressed", .init(pressed: true), true, true)
        ]
        for theme in [LLTheme.stellar, .wilds] {
            for (name, state, enabled, reduced) in states {
                let view = DockUtilityActions()
                    .environment(\.dockInteractionPreview,
                                 DockInteraction(hovered: state.hovered, pressed: state.pressed, reduceMotion: reduced))
                    .disabled(!enabled)
                    .padding(.horizontal, 28)
                    .frame(width: 250, height: 76)
                    .background(theme.ground)
                try render(view, theme: theme, size: CGSize(width: 250, height: 76),
                           to: directory.appendingPathComponent("\(theme.isDark ? "dark" : "light")-\(name).png"))
            }
        }
    }

    static func renderSourceConfiguration(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.source-popover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.listenSourceLanguage = "zh-Hans"
        settings.listenTargetLanguage = "en"
        let idle = AppModel(settings: settings, preview: .empty())
        func capture<V: View>(_ view: V, _ name: String, theme: LLTheme = .stellar) throws {
            try render(view.fixedSize().environment(\.staticMotionTime, 2.3), theme: theme,
                       size: nil, to: directory.appendingPathComponent(name + ".png"))
        }
        try capture(SessionSourcePopover(onClose: {}).environment(idle), "idle-dark")
        try capture(SessionSourcePopover(onClose: {}).environment(idle), "idle-light", theme: .wilds)
        idle.applyMode(.converse)
        try capture(SessionSourcePopover(onClose: {}).environment(idle), "dual-dark")
        try capture(SessionLanguagePopover(onClose: {}).environment(idle), "languages-dark")
        idle.useSystem = false
        idle.useApplication = false
        idle.useMicrophone = false
        try capture(SessionSourcePopover(onClose: {}).environment(idle), "no-source-dark")
        let active = AppModel(settings: settings, preview: SampleData.runningSnapshot(dual: true))
        var selection = SessionSourceSelection(model: active)
        try capture(ActiveSessionSourceEditor(selection: selection).environment(active), "active-dual-dark")
        selection.languages.listenTarget = "ja"
        try capture(ActiveSessionSourceEditor(selection: selection).environment(active), "active-edited-dark")
        selection.computer = .off
        selection.microphoneEnabled = false
        try capture(ActiveSessionSourceEditor(selection: selection).environment(active), "active-invalid-dark")
    }

    static func renderBrowserExtension(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.browser-preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.requestedSettingsTab = .browserExtension
        let model = AppModel(settings: settings, preview: .empty())
        for theme in [LLTheme.stellar, .wilds] {
            try render(SettingsView().environment(model), theme: theme, size: SettingsView.size,
                       to: directory.appendingPathComponent(theme.isDark ? "settings-dark.png" : "settings-light.png"))
        }
    }

    static func renderUnifiedNebula(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.nebula-unified.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: .empty())
        let size = LLMetrics.defaultWindow
        for mode in SessionMode.allCases {
            model.applyMode(mode)
            try render(RootView().environment(model).environment(\.staticMotionTime, 2.3), theme: .stellar, size: size,
                       to: directory.appendingPathComponent("mode-\(mode.rawValue).png"))
        }
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for frame in 0..<90 {
            let time = Double(frame) / 15
            if frame == 0 { model.applyMode(.listen) }
            if frame == 30 { model.applyMode(.converse) }
            if frame == 60 { model.applyMode(.faceToFace) }
            try render(RootView().environment(model).environment(\.staticMotionTime, time), theme: .stellar, size: size,
                       to: frames.appendingPathComponent(String(format: "%03d.png", frame)), scale: 1)
        }
        model.applyMode(.listen)
        for state in [SessionState.running, .paused] {
            var snapshot = SampleData.runningSnapshot()
            snapshot.state = state
            let session = AppModel(settings: settings, preview: snapshot)
            try render(RootView().environment(session).environment(\.staticMotionTime, 2.3), theme: .stellar, size: size,
                       to: directory.appendingPathComponent("session-\(state.rawValue).png"))
        }
    }

    static func renderNavigationStars(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.navigation-stars.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), preview: .empty())
        let size = CGSize(width: 960, height: 112)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let motion = NavigationStarMotion()
        for frame in 0..<360 {
            let time = Double(frame) / 60
            let selection = frame < 120 ? 1 : (frame < 240 ? 2 : 0)
            if frame == 120 { model.requestVocabularyWindow() }
            if frame == 240 { model.requestRecords() }
            let points = motion.sample(time: time, selection: selection)
            let view = MainNavigationDock(openRecords: {}, goHome: {}, previewStarPoints: points, previewTime: time)
                .environment(model).frame(width: size.width, height: size.height).background(LLTheme.stellar.ground)
            try render(view, theme: .stellar, size: size,
                       to: frames.appendingPathComponent(String(format: "%03d.png", frame)))
            if [110, 126, 138, 150, 230, 246, 258, 270, 350].contains(frame) {
                try render(view, theme: .stellar, size: size, to: directory.appendingPathComponent("navigation-\(frame).png"))
            }
        }
        model.requestVocabularyWindow()
        for time in [0.0, 155.0, 600.0] {
            let points = (0..<NavigationStarMotion.count).map { NavigationStarMotion.target($0, selection: 2, time: time) }
            let view = MainNavigationDock(openRecords: {}, goHome: {}, previewStarPoints: points, previewTime: time)
                .environment(model).frame(width: size.width, height: size.height).background(LLTheme.stellar.ground)
            try render(view, theme: .stellar, size: size,
                       to: directory.appendingPathComponent("navigation-rest-\(Int(time)).png"))
        }
    }

    static func renderMembrane(to directory: URL) throws {
        try renderOrganism(to: directory, stardust: false)
    }

    static func renderStardust(to directory: URL, activity: Double = 0) throws {
        try renderOrganism(to: directory, stardust: true, activity: activity)
    }

    private static func renderOrganism(to directory: URL, stardust: Bool, activity: Double = 0) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 440, height: 440)
        @ViewBuilder func organism(_ time: Double, pointer: CGPoint? = nil, pulse: Double = 0) -> some View {
            if stardust {
                StardustOrganism(time: time * (1 + activity * 3.2), pointer: pointer, influence: pointer == nil ? 0 : 1, pulse: pulse, activity: activity)
            } else {
                MembraneOrganism(time: time, pointer: pointer, influence: pointer == nil ? 0 : 1, pulse: pulse)
            }
        }
        func capture(_ time: Double, name: String, pointer: CGPoint? = nil, theme: LLTheme = .stellar, pulse: Double = 0) throws {
            try render(organism(time, pointer: pointer, pulse: pulse)
                .frame(width: 360, height: 360).frame(width: size.width, height: size.height).background(theme.ground),
                       theme: theme, size: size, to: directory.appendingPathComponent(name + ".png"))
        }
        for t in [0.0, 1.5, 3, 5.8] { try capture(t, name: "\(stardust ? "stardust" : "membrane")-\(t)") }
        try capture(1.5, name: "pointer", pointer: CGPoint(x: 0.82, y: 0.30), pulse: 0.4)
        try capture(1.5, name: "light", theme: .wilds)
        let suite = "LiveLearn.testing.membrane.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for state in [SessionState.idle, .running, .paused] {
            var snapshot = state == .idle ? .empty() : SampleData.runningSnapshot()
            snapshot.state = state
            let model = AppModel(settings: settings, preview: snapshot)
            try render(RootView().environment(model), theme: .stellar, size: state == .idle ? LLMetrics.defaultWindow : LLMetrics.minWindow,
                       to: directory.appendingPathComponent("home-\(state.rawValue).png"))
        }
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for frame in 0..<120 {
            let t = Double(frame) / 20
            try render(organism(t).frame(width: 320, height: 320)
                .frame(width: 380, height: 380).background(LLTheme.stellar.ground),
                       theme: .stellar, size: CGSize(width: 380, height: 380),
                       to: frames.appendingPathComponent(String(format: "%03d.png", frame)))
        }
    }

    static func renderBreathingTransport(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 420, height: 120)
        func capture<V: View>(_ view: V, _ name: String, theme: LLTheme = .stellar) throws {
            try render(view.frame(width: size.width, height: size.height).background(theme.ground), theme: theme, size: size,
                       to: directory.appendingPathComponent(name + ".png"))
        }
        for appearance in [SessionActionAppearance.start, .pause, .resume, .connecting] {
            try capture(transportPreview(appearance, time: 0), "\(appearance.rawValue)-rest")
            try capture(transportPreview(appearance, time: 2.3), "\(appearance.rawValue)-peak")
        }
        try capture(transportPreview(.pause, time: 2.3, hovered: true), "pause-hover")
        try capture(transportPreview(.pause, time: 2.3).disabled(true), "disabled")
        try capture(transportPreview(.pause, time: 2.3, reduced: true), "reduce-motion")
        try capture(transportPreview(.pause, time: 2.3), "light", theme: .wilds)
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for frame in 0..<92 {
            let view = transportPreview(.pause, time: Double(frame) / 20)
                .frame(width: size.width, height: size.height).background(LLTheme.stellar.ground)
            try render(view, theme: .stellar, size: size, to: frames.appendingPathComponent(String(format: "%03d.png", frame)))
        }
    }

    private static func transportPreview(_ appearance: SessionActionAppearance, time: Double, hovered: Bool = false, reduced: Bool = false) -> some View {
        SessionControlRail {
            LuminousActionButton(appearance: appearance,
                                 frozenTime: time, previewHovered: hovered, previewReducedMotion: reduced, action: {})
            if appearance != .start {
                LuminousActionButton(appearance: .stop, frozenTime: 0, action: {})
            }
        }
    }

    static func renderLivingControls(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.living-controls.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func capture<V: View>(_ view: V, _ name: String, theme: LLTheme = .stellar, size: CGSize = LLMetrics.defaultWindow) throws {
            try render(view.frame(width: size.width, height: size.height).background(theme.ground),
                       theme: theme, size: size, to: directory.appendingPathComponent(name + ".png"))
        }
        let idle = AppModel(settings: settings, preview: .empty())
        try capture(RootView().environment(idle), "home-ready")
        try capture(RootView().environment(idle), "home-minimum", size: LLMetrics.minWindow)
        try capture(RootView().environment(idle), "home-light", theme: .wilds)
        let live = AppModel(settings: settings, preview: SampleData.runningSnapshot())
        let dual = AppModel(settings: settings, preview: SampleData.runningSnapshot(dual: true))
        // Every page the sidebar offers, 网页翻译 included, so no page goes without a baseline.
        for tab in [SettingsTab.sources, .language, .engine, .localModels, .appearance, .shortcuts, .privacy, .diagnostics, .theme, .browserExtension] {
            settings.requestedSettingsTab = tab
            try capture(SettingsView().environment(idle), "settings-\(tab.rawValue)", size: SettingsView.size)
        }
        settings.requestedSettingsTab = .sources
        try capture(SettingsView().environment(idle), "settings-light", theme: .wilds, size: SettingsView.size)
        // The modal as the default 1180 × 760 window actually shows it: `modalRect` leaves a
        // 1014 × 668 card there, 72 pt shorter than the 1080 × 740 maximum every other settings
        // preview uses. It is the only capture that shows where the card cuts a page at the size
        // most people run, and the one the "nothing clipped at 1180 × 760" lens is checked
        // against; without it the 音源与设备 clipping was invisible to the whole render set.
        try capture(SettingsView().environment(idle),
                    "settings-sources-default",
                    size: LiveLearnSettingsPage.modalRect(in: CGRect(origin: .zero, size: LLMetrics.defaultWindow)).size)
        // The modal at its minimum (the 960 × 600 window). ImageRenderer draws no scroll views,
        // so this is the sidebar and the page as they stand before either is scrolled: the last
        // sidebar rows and the last controls are cut at the card's bottom edge, where the real
        // modal scrolls them into view.
        try capture(SettingsView().environment(idle), "settings-sources-minimum", size: CGSize(width: 825, height: 528))
        for pane in [AppearancePane.layout, .behavior] {
            try capture(AppearanceSettings(previewPane: pane).environment(idle), "settings-appearance-\(pane.rawValue)", size: CGSize(width: LiveLearnSettingsPage.contentMeasure + 64, height: 620))
        }
        live.requestRecords()
        try capture(RootView(previewHistoryVisible: true).environment(live), "records-open")
        try capture(RootView(previewHistoryVisible: false).environment(live), "records-closed")
        live.requestHome()
        for interacting in [false, true] {
            let input = ParticleInteraction()
            input.setHeroFrame(CGRect(x: 150, y: 40, width: 300, height: 300))
            if interacting {
                input.move(to: CGPoint(x: 430, y: 170), dragging: true, at: Date.timeIntervalSinceReferenceDate - 0.4)
                input.pulse(at: CGPoint(x: 430, y: 170), time: Date.timeIntervalSinceReferenceDate - 0.45)
            }
            try capture(ZStack {
                LuminousParticleFlow(active: false, frozenTime: 1)
                SessionOrbHero(diameter: 300, frozenTime: 1).position(x: 300, y: 190)
                SessionControlRail { LuminousActionButton(appearance: .start, frozenTime: 1, action: {}) }
                    .position(x: 300, y: 412)
            }.frame(width: 600, height: 480).environment(\.particleInteraction, input),
                        "interaction-\(interacting ? "pointer" : "rest")", size: CGSize(width: 600, height: 480))
        }
        try capture(SessionSourcePopover(onClose: {}).environment(idle), "source-idle-fields", size: CGSize(width: 480, height: 350))
        try capture(ActiveSessionSourceEditor(selection: SessionSourceSelection(model: live)).environment(live),
                    "source-active", size: CGSize(width: 480, height: 400))
        var dualSource = SessionSourceSelection(model: live)
        dualSource.microphoneEnabled = true
        try capture(ActiveSessionSourceEditor(selection: dualSource).environment(live),
                    "source-active-dual", size: CGSize(width: 480, height: 470))
        for width in [CGFloat(640), 940, 1440] {
            try capture(TopBar(availableWidth: width).environment(live), "status-single-\(Int(width))", size: CGSize(width: width, height: 64))
            try capture(TopBar(availableWidth: width).environment(dual), "status-dual-\(Int(width))", size: CGSize(width: width, height: 72))
        }
        for state in [SessionState.preparing, .connecting, .running, .paused, .draining, .stopping] {
            var snapshot = SampleData.runningSnapshot()
            snapshot.state = state
            let model = AppModel(settings: settings, preview: snapshot)
            try capture(RootView().environment(model), "home-\(state.rawValue)", size: LLMetrics.minWindow)
        }
        for appearance in SessionActionAppearance.allCases {
            for enabled in [true, false] {
                try capture(LuminousActionButton(appearance: appearance, frozenTime: 0.8, action: {}).disabled(!enabled),
                            "button-\(appearance.rawValue)-\(enabled ? "enabled" : "disabled")", size: CGSize(width: 340, height: 120))
            }
        }
        try capture(LuminousActionButton(appearance: .start, frozenTime: 0.4,
                                         previewRipple: 0.18, previewPressed: true, action: {}), "button-ripple", size: CGSize(width: 340, height: 120))
        try capture(LuminousActionButton(appearance: .connecting, frozenTime: 0,
                                         previewReducedMotion: true, action: {}), "button-reduce-motion", size: CGSize(width: 340, height: 120))
        let frames = directory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        for frame in 0..<80 {
            let t = Double(frame) / 20
            let appearance: SessionActionAppearance = t < 1 ? .start : (t < 2 ? .connecting : (t < 3 ? .pause : .resume))
            let ripple: Double? = (1..<1.65).contains(t) ? (t - 1) / 0.65 : nil
            try render(VStack(spacing: 24) {
                SessionOrbHero(diameter: 260, frozenTime: t)
                SessionControlRail {
                    LuminousActionButton(appearance: appearance, frozenTime: t,
                                         previewRipple: ripple, previewPressed: (0.9..<1.05).contains(t), action: {})
                    if appearance != .start {
                        LuminousActionButton(appearance: .stop, frozenTime: t, action: {})
                    }
                }
            }.frame(width: 400, height: 380).background(LLTheme.stellar.ground),
                       theme: .stellar, size: CGSize(width: 400, height: 380),
                       to: frames.appendingPathComponent(String(format: "%03d.png", frame)))
        }
    }

    static func renderStarMap(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.starmap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(settings: settings, preview: .empty())
        model.mainPage = .vocabulary
        func capture<V: View>(_ view: V, _ name: String, theme: LLTheme = .stellar, size: CGSize = LLMetrics.defaultWindow) throws {
            try render(view, theme: theme, size: size, to: directory.appendingPathComponent(name + ".png"))
        }
        try capture(RootView().environment(model), "empty-dark")
        try capture(RootView().environment(model), "empty-minimum", size: LLMetrics.minWindow)
        for (name, state, searching) in [
            ("add-idle", DockInteraction(), false),
            ("add-hover", DockInteraction(hovered: true), false),
            ("add-pressed", DockInteraction(hovered: true, pressed: true), false),
            ("clear-search", DockInteraction(), true)
        ] {
            let map = VocabularyStarMap(items: [], isSearching: searching, isVisible: true,
                                        selectedID: .constant(nil), onAdd: {}, onClearSearch: {}, onEdit: { _ in })
                .environment(\.dockInteractionPreview, state)
                .background(LLTheme.stellar.ground)
            try capture(map, name, size: CGSize(width: 660, height: 400))
        }
        settings.hotWords = ["LiveLearn", "WhisperKit", "SwiftUI", "Core Audio", "语音识别", "深度学习", "OpenAI", "Apple Silicon", "神经网络", "Transformer", "麦克风", "语言模型", "声纹", "多模态", "Metal", "注意力机制"]
        settings.glossaryLines = ["latency=时延", "machine learning=机器学习", "constellation=星座", "inference=推理", "embedding=嵌入", "context window=上下文窗口", "real-time=实时", "token=词元", "alignment=对齐", "streaming=流式传输", "neural network=神经网络", "fine-tuning=微调", "acoustic model=声学模型", "speech recognition=语音识别", "translation=翻译", "attention=注意力"]
        try capture(RootView().environment(model), "populated-dark")
        try capture(RootView().environment(model), "populated-minimum", size: LLMetrics.minWindow)
        try capture(RootView().environment(model), "populated-light", theme: .wilds)
        try capture(VocabularyWindowView(previewStarMap: false).environment(model), "list-dark", size: VocabularyWindowView.size)
        try capture(VocabularyWindowView(previewQuery: "不存在").environment(model), "no-results", size: VocabularyWindowView.minimumSize)
        settings.hotWords += (1...500).map { "词汇-\($0)" }
        try capture(RootView().environment(model), "large-library", size: LLMetrics.minWindow)
        model.mainPage = .home
        try capture(RootView().environment(model), "home-dark")
        try capture(RootView().environment(model), "home-dark-minimum", size: LLMetrics.minWindow)
        try capture(RootView().environment(model), "home-light", theme: .wilds)
        try capture(RootView().environment(model), "home-contrast", theme: .stellar.increasedContrast())
        model.applyMode(.converse)
        try capture(RootView().environment(model), "home-conversation", size: LLMetrics.minWindow)
        let running = AppModel(settings: settings, preview: SampleData.runningSnapshot())
        try capture(RootView().environment(running), "home-active", size: LLMetrics.minWindow)
        model.requestRecords()
        try capture(RootView(previewHistoryVisible: true).environment(model), "records-dark", size: LLMetrics.minWindow)
        settings.requestedSettingsTab = .theme
        try capture(SettingsView().environment(model), "settings-dark", size: SettingsView.size)
    }

    static func renderExplorationThemes(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.exploration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let idle = AppModel(settings: settings, preview: .empty())
        for world in ExperienceTheme.allCases {
            settings.experienceTheme = world
            let theme: LLTheme = world == .stellar ? .stellar : .wilds
            let mesh = ExplorationWorldModel(world: world, animated: false)
            print("\(world.rawValue): \(mesh.triangleCount) triangles; \(mesh.imageTextureCount) image textures")
            func capture<V: View>(_ view: V, _ name: String, size: CGSize = LLMetrics.defaultWindow) throws {
                try render(view, theme: theme, size: size, to: directory.appendingPathComponent("\(world.rawValue)-\(name).png"))
            }
            idle.mainPage = .home
            try capture(RootView().environment(idle), "home")
            try capture(RootView().environment(idle), "home-minimum", size: LLMetrics.minWindow)
            idle.mainPage = .vocabulary
            try capture(RootView().environment(idle), "vocabulary", size: LLMetrics.minWindow)
            idle.requestRecords()
            try capture(RootView(previewHistoryVisible: true).environment(idle), "records", size: LLMetrics.minWindow)
            for tab in [SettingsTab.sources, .language, .engine, .localModels, .appearance, .shortcuts, .privacy, .diagnostics, .theme] {
                settings.requestedSettingsTab = tab
                try capture(SettingsView().environment(idle), "settings-\(tab.rawValue)", size: SettingsView.size)
            }
            let running = AppModel(settings: settings, preview: SampleData.runningSnapshot())
            try capture(RootView().environment(running), "active", size: LLMetrics.minWindow)
            var paused = SampleData.runningSnapshot(dual: true)
            paused.state = .paused
            try capture(RootView().environment(AppModel(settings: settings, preview: paused)), "paused", size: LLMetrics.minWindow)
            var failed = SessionSnapshot.empty()
            failed.state = .failed
            failed.failure = "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。"
            try capture(RootView().environment(AppModel(settings: settings, preview: failed)), "failed", size: LLMetrics.minWindow)
            try capture(OverlayView(forcedWidth: 880, previewControls: true).environment(running), "overlay-controls", size: CGSize(width: 880, height: 300))
            for time in [0.0, 8.0] {
                try capture(ExplorationBackdrop(immersive: true, frozenTime: time), "motion-\(Int(time))")
            }
        }
    }

    static func renderMainLayout(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.main-layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func model(_ snapshot: SessionSnapshot) -> AppModel {
            let model = AppModel(settings: settings, preview: snapshot)
            for n in 1...3 {
                var record = SampleData.runningSnapshot(dual: n == 2, includeGap: false)
                record.sessionID = "layout-record-\(n)"
                record.captions.sessionID = record.sessionID
                record.state = .completed
                record.elapsedNs = Int64(n * 124) * 1_000_000_000
                model.receive(record)
            }
            model.receive(snapshot)
            return model
        }
        let idle = model(.empty())
        for theme in [LLTheme.light, .dark] {
            try render(RootView().environment(idle), theme: theme, size: LLMetrics.defaultWindow,
                       to: directory.appendingPathComponent("home-\(theme.isDark ? "dark" : "light").png"))
        }
        try render(RootView().environment(idle), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("home-minimum.png"))
        idle.applyMode(.converse)
        try render(RootView(previewHistoryVisible: true).environment(idle), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("home-dual-history-minimum.png"))
        idle.applyMode(.listen)
        idle.requestRecords()
        try render(RootView().environment(idle), theme: .light, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("records-entry.png"))
        let emptyRecords = AppModel(settings: settings, preview: .empty())
        emptyRecords.requestRecords()
        try render(RootView().environment(emptyRecords), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("records-empty.png"))
        settings.hotWords = ["LiveLearn", "WhisperKit", "飞书"]
        settings.glossaryLines = ["latency=时延", "machine learning=机器学习"]
        idle.mainPage = .vocabulary
        try render(RootView().environment(idle), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("vocabulary-inline-minimum.png"))
        try render(RootView().environment(idle), theme: .dark, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("vocabulary-inline-dark.png"))
        idle.mainPage = .home
        let running = model(SampleData.runningSnapshot())
        try render(RootView().environment(running), theme: .light, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("home-live-light.png"))
        try render(RootView().environment(running), theme: .dark, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("home-live-dark-minimum.png"))
        running.overlayVisible = false
        try render(RootView().environment(running), theme: .light, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("home-subtitles-off.png"))
        running.overlayVisible = true
        try render(ActiveSessionSourceEditor(selection: SessionSourceSelection(model: running)).environment(running),
                   theme: .light, size: CGSize(width: 480, height: 400),
                   to: directory.appendingPathComponent("active-source-editor.png"))
        running.mainPage = .transcript
        for visible in [true, false] {
            try render(RootView(previewHistoryVisible: visible).environment(running), theme: .light,
                       size: LLMetrics.defaultWindow, to: directory.appendingPathComponent("session-history-\(visible ? "open" : "closed").png"))
        }
        try render(RootView().environment(running), theme: .dark, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("session-dark.png"))
        var paused = SampleData.runningSnapshot(dual: true)
        paused.state = .paused
        try render(RootView().environment(model(paused)), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("paused-dual-minimum.png"))
        let finished = model(paused)
        if let record = finished.records.first { finished.showRecord(record) }
        // A preview model still obeys the real guard: finish before opening its history.
        var terminal = paused
        terminal.state = .completed
        finished.receive(terminal)
        if let record = finished.records.last { finished.showRecord(record) }
        try render(RootView().environment(finished), theme: .light, size: LLMetrics.minWindow,
                   to: directory.appendingPathComponent("record-minimum.png"))
        // The records page in the dark as it is read back and as a failed session leaves it
        // (the recovery note over the empty page), and the horizon under the vocabulary page
        // while a session runs.
        let reading = model(.empty())
        reading.requestRecords()
        try render(RootView(previewHistoryVisible: true).environment(reading), theme: .dark, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("record-dark.png"))
        var failed = SessionSnapshot.empty()
        failed.state = .failed
        failed.failure = "系统音频录制未获授权。请在系统设置中允许 LiveLearn，然后重新开始。"
        let stopped = model(failed)
        stopped.requestRecords()
        try render(RootView(previewHistoryVisible: true).environment(stopped), theme: .dark, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("failed-dark.png"))
        let listening = model(SampleData.runningSnapshot())
        listening.mainPage = .vocabulary
        try render(RootView().environment(listening), theme: .dark, size: LLMetrics.defaultWindow,
                   to: directory.appendingPathComponent("vocabulary-live-dark.png"))
        try Round12HomePreviews.renderRecoveryStates(settings: settings, model: model) { try render($0, theme: $1, size: $2, to: directory.appendingPathComponent($3 + ".png")) }
    }

    static func renderReadability(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.readability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let size = CGSize(width: 880, height: 300)
        for preset in ["white", "kai-black", "mixed", "manual"] {
            settings.resetOverlayStyle()
            settings.overlayTextHex = preset == "white" ? "FFFFFF" : "000000"
            if preset == "kai-black" { settings.overlayFontFamily = OverlayTypography.kaiFamily ?? ""; settings.overlayTextWeight = .regular }
            if preset == "mixed" { settings.overlayTextHex = "FFCD38"; settings.overlaySourceHex = "141414" }
            if preset == "manual" { settings.overlayContrastMode = .manual; settings.overlayOutlineWidth = 0 }
            for scene in CaptionPreviewScene.allCases {
                try render(CaptionPreviewSurface(settings: settings, scene: scene), theme: .light, size: size,
                           to: directory.appendingPathComponent("\(preset)-\(scene.rawValue).png"))
            }
        }
        settings.resetOverlayStyle()
        let model = AppModel(settings: settings, preview: SampleData.runningSnapshot())
        try render(OverlayView(forcedWidth: 880).environment(model), theme: .dark, size: CGSize(width: 880, height: 280),
                   to: directory.appendingPathComponent("transparent-overlay.png"))
        settings.requestedSettingsTab = .appearance
        try render(SettingsView().environment(model), theme: .light, size: SettingsView.size,
                   to: directory.appendingPathComponent("settings.png"))
        try render(SettingsView().environment(model), theme: .dark, size: SettingsView.size,
                   to: directory.appendingPathComponent("settings-dark.png"))
        for pane in [AppearancePane.layout, .behavior] {
            try render(AppearanceSettings(previewPane: pane).environment(model), theme: .light,
                       size: CGSize(width: LiveLearnSettingsPage.contentMeasure + 64, height: 620), to: directory.appendingPathComponent("settings-\(pane.rawValue).png"))
        }
        for preset in OverlayAppearancePreset.allCases where preset.isAvailable {
            preset.apply(to: settings)
            try render(CaptionPreviewSurface(settings: settings, scene: preset == .kai ? .light : .dark), theme: .light,
                       size: size, to: directory.appendingPathComponent("preset-\(preset.rawValue).png"))
        }
        settings.resetOverlayStyle()
        for frame in 0..<3 {
            try render(RecognitionOrb(lightInk: true, frozenTime: Double(frame) * 0.65).padding(14).background(Color(hex: 0x191919)),
                       theme: .dark, size: CGSize(width: 64, height: 64), to: directory.appendingPathComponent("recognition-orb-\(frame).png"))
        }
        settings.hotWords = ["LiveLearn", "飞书"]
        var reviewSnapshot = SampleData.runningSnapshot(includeGap: false)
        if case .segment(var segment) = reviewSnapshot.captions.items[0] {
            segment.sourceText = "Open live lawn，用飞鼠开会。"
            segment.sourceFinal = true
            segment.vocabularyCandidates = VocabularyCandidateGenerator(vocabulary: settings.hotWords).candidates(in: segment.sourceText)
            reviewSnapshot.captions.items = [.segment(segment)]
        }
        let review = AppModel(settings: settings, preview: reviewSnapshot)
        try render(VocabularyWindowView(previewSection: .corrections).environment(review), theme: .light,
                   size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-corrections.png"))
        settings.overlayFontFamily = OverlayTypography.kaiFamily ?? ""
        settings.overlayTextHex = "000000"
        settings.captionTargetSize = 40
        settings.captionSourceSize = 28
        settings.showPreviousLine = true
        try render(CaptionPreviewSurface(settings: settings, scene: .highContrast), theme: .light,
                   size: CGSize(width: 480, height: 520), to: directory.appendingPathComponent("kai-large-narrow.png"))
        settings.resetOverlayStyle()
        let frames = directory.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let blackDefaults = UserDefaults(suiteName: suite + ".black")!
        defer { blackDefaults.removePersistentDomain(forName: suite + ".black") }
        let black = AppSettings(defaults: blackDefaults)
        black.overlayFontFamily = OverlayTypography.kaiFamily ?? ""
        black.overlayTextHex = "000000"
        black.overlayTextWeight = .regular
        for (sceneIndex, scene) in CaptionPreviewScene.allCases.enumerated() {
            for frame in 0..<24 {
                let content = VStack(spacing: 0) {
                    Text("\(scene.label)画面 · 自动对比 · 背景 0%")
                        .font(.system(size: 18)).foregroundStyle(.white).padding(14)
                        .frame(maxWidth: .infinity).background(Color(hex: 0x232323))
                    CaptionPreviewSurface(settings: settings, scene: scene, phase: Double(frame) / 6)
                    CaptionPreviewSurface(settings: black, scene: scene, phase: Double(frame) / 6)
                }
                try render(content, theme: .light, size: CGSize(width: 880, height: 480),
                           to: frames.appendingPathComponent(String(format: "%04d.png", sceneIndex * 24 + frame)))
            }
        }
    }

    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLearn.testing.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)

        let running = AppModel(settings: settings, preview: SampleData.runningSnapshot())
        let awaiting = AppModel(settings: settings, preview: SampleData.awaitingTranslationSnapshot())
        let dual = AppModel(settings: settings, preview: SampleData.runningSnapshot(dual: true))
        var pausedSnapshot = SampleData.runningSnapshot()
        pausedSnapshot.state = .paused
        let paused = AppModel(settings: settings, preview: pausedSnapshot)
        let idle = AppModel(settings: settings, preview: .empty())
        var finalSnapshot = SampleData.runningSnapshot()
        finalSnapshot.captions.items.removeAll { item in
            if case .segment(let segment) = item { return segment.translation == nil }
            return false
        }
        let subtitles = AppModel(settings: settings, preview: finalSnapshot)
        idle.select(applications: [RunningApplicationSummary(bundleIdentifier: "com.apple.Safari", name: "Safari", path: nil, pid: 0, isPlayingAudio: true)])

        let window = LLMetrics.defaultWindow

        try render(RootView().environment(running), theme: .light, size: window, to: directory.appendingPathComponent("main-light.png"))
        try render(RootView().environment(running), theme: .dark, size: window, to: directory.appendingPathComponent("main-dark.png"))
        try render(RootView().environment(idle), theme: .light, size: window, to: directory.appendingPathComponent("main-empty-light.png"))
        // Dark: the start mark and the resting sound lines on the dark ground.
        try render(RootView().environment(idle), theme: .dark, size: window, to: directory.appendingPathComponent("main-empty-dark.png"))
        try render(RootView().environment(idle), theme: .light, size: LLMetrics.minWindow, to: directory.appendingPathComponent("main-setup-minimum.png"))
        idle.applyMode(.converse)
        try render(RootView().environment(idle), theme: .light, size: LLMetrics.minWindow, to: directory.appendingPathComponent("main-setup-dual-minimum.png"))
        idle.applyMode(.faceToFace)
        try render(RootView().environment(idle), theme: .dark, size: window, to: directory.appendingPathComponent("main-setup-microphone-dark.png"))
        idle.applyMode(.listen)
        try render(RootView().environment(dual), theme: .light, size: window, to: directory.appendingPathComponent("main-dual-light.png"))
        // Paused: the resume mark is the only vermilion in the bar.
        try render(RootView().environment(paused), theme: .light, size: window, to: directory.appendingPathComponent("main-paused-light.png"))
        try render(RootView().environment(paused), theme: .dark, size: window, to: directory.appendingPathComponent("main-paused-dark.png"))

        let overlayWidth: CGFloat = 820
        try render(VideoBackdrop(bright: false) { OverlayView(forcedWidth: overlayWidth).environment(subtitles) }, theme: .dark, size: CGSize(width: 1280, height: 420), to: directory.appendingPathComponent("overlay-on-dark.png"))
        try render(VideoBackdrop(bright: true) { OverlayView(forcedWidth: overlayWidth).environment(awaiting) }, theme: .light, size: CGSize(width: 1280, height: 420), to: directory.appendingPathComponent("overlay-on-bright.png"))
        try render(VideoBackdrop(bright: false) { OverlayView(forcedWidth: overlayWidth).environment(dual) }, theme: .dark, size: CGSize(width: 1280, height: 520), to: directory.appendingPathComponent("overlay-dual.png"))
        try render(VideoBackdrop(bright: false) { OverlayView(forcedWidth: overlayWidth, previewControls: true).environment(subtitles) }, theme: .dark, size: CGSize(width: 1280, height: 420), to: directory.appendingPathComponent("overlay-controls.png"))
        subtitles.overlayLocked = true
        try render(VideoBackdrop(bright: false) { OverlayView(forcedWidth: overlayWidth, previewControls: true).environment(subtitles) }, theme: .dark, size: CGSize(width: 1280, height: 420), to: directory.appendingPathComponent("overlay-locked-controls.png"))
        subtitles.overlayLocked = false
        // No backdrop: the PNG alpha verifies that 0% leaves no panel, border or shadow.
        try render(OverlayView(forcedWidth: overlayWidth).environment(subtitles), theme: .dark, size: CGSize(width: overlayWidth, height: 260), to: directory.appendingPathComponent("overlay-transparent.png"))
        settings.captionTargetSize = 40
        settings.captionSourceSize = 28
        try render(VideoBackdrop(bright: true) { OverlayView(forcedWidth: 480, previewControls: true).environment(subtitles) }, theme: .light, size: CGSize(width: 800, height: 520), to: directory.appendingPathComponent("overlay-narrow-large-type.png"))
        settings.resetOverlayStyle()
        settings.overlayOpacity = 0.45
        try render(VideoBackdrop(bright: true) { OverlayView(forcedWidth: overlayWidth).environment(subtitles) }, theme: .light, size: CGSize(width: 1280, height: 420), to: directory.appendingPathComponent("overlay-soft-background.png"))
        settings.resetOverlayStyle()

        try render(MenuBarView().environment(running), theme: .light, size: CGSize(width: LLMetrics.menuWidth, height: 560), to: directory.appendingPathComponent("menubar-light.png"))
        try render(MenuBarView().environment(running), theme: .dark, size: CGSize(width: LLMetrics.menuWidth, height: 560), to: directory.appendingPathComponent("menubar-dark.png"))

        // Settings pages: layout only (sliders, color wells and fields are AppKit-backed and may
        // not draw offscreen); the real window is checked with ⌘, in the app.
        settings.requestedSettingsTab = .sources
        try render(SettingsView().environment(idle), theme: .light, size: SettingsView.size, to: directory.appendingPathComponent("settings-sources-light.png"))
        settings.requestedSettingsTab = .appearance
        settings.controlSessionOnOverlayClose = true
        settings.overlayCloseAction = .pause
        try render(SettingsView().environment(idle), theme: .light, size: SettingsView.size, to: directory.appendingPathComponent("settings-overlay-close-pause.png"))
        settings.overlayCloseAction = .endSession
        try render(SettingsView().environment(idle), theme: .dark, size: SettingsView.size, to: directory.appendingPathComponent("settings-overlay-close-end.png"))
        settings.controlSessionOnOverlayClose = false
        try render(SettingsView().environment(idle), theme: .light, size: SettingsView.size, to: directory.appendingPathComponent("settings-appearance-light.png"))
        try render(SettingsView().environment(idle), theme: .dark, size: SettingsView.size, to: directory.appendingPathComponent("settings-appearance-dark.png"))
        // Engine page with a cloud pair chosen, so the address / model / key rows and the data
        // destination line are all on the sheet.
        settings.requestedSettingsTab = .engine
        settings.recognizer = .openAIRealtime
        settings.translator = .chat
        settings.chatVendor = .deepseek
        // 1260, not the page's usual height: the two 模型 rows sit under their names now and each
        // one grew from ~52 to 88 pt, about 71 pt for the page, which would push 数据去向 and 费用
        // off a 1180 pt canvas.
        try render(SettingsView().environment(idle), theme: .light, size: CGSize(width: SettingsView.size.width, height: 1260), to: directory.appendingPathComponent("settings-engine-light.png"))
        // The same page in the user's own theme: a `QuietField` is a lighter paper on paper in the
        // light theme and a brighter graphite on black in the dark one, so a column of six of them
        // is a different weight there and this is the only render that shows it.
        try render(SettingsView().environment(idle), theme: .dark, size: CGSize(width: SettingsView.size.width, height: 1260), to: directory.appendingPathComponent("settings-engine-dark.png"))
        settings.recognizer = .appleSpeech
        settings.translator = .appleTranslation
        // Models page: the Apple assets and the Whisper variants as this Mac has them.
        settings.requestedSettingsTab = .localModels
        try render(SettingsView().environment(idle), theme: .light, size: CGSize(width: SettingsView.size.width, height: 1100), to: directory.appendingPathComponent("settings-models-light.png"))
        // Vocabulary: empty onboarding, populated list, and both system appearances.
        settings.requestedSettingsTab = .vocabulary
        settings.hotWords = []
        settings.glossaryLines = []
        let importText = "WhisperKit\nmachine learning=机器学习\nlatency=延迟"
        for theme in [LLTheme.light, .dark] {
            let suffix = theme.isDark ? "dark" : "light"
            try render(importPreview(text: ""), theme: theme, size: CGSize(width: 568, height: 450), to: directory.appendingPathComponent("vocabulary-import-empty-\(suffix).png"))
            try render(importPreview(text: importText, expanded: true), theme: theme, size: CGSize(width: 568, height: 450), to: directory.appendingPathComponent("vocabulary-import-review-\(suffix).png"))
        }
        try render(importPreview(text: importText, fileName: "课程词汇.tsv"), theme: .light, size: CGSize(width: 568, height: 450), to: directory.appendingPathComponent("vocabulary-import-file-light.png"))
        try render(importPreview(text: "latency=时延\nWhisperKit\nnew term=新术语", library: VocabularyLibrary(hotWords: ["WhisperKit"], glossaryLines: ["latency=延迟"]), expanded: true), theme: .light, size: CGSize(width: 568, height: 450), to: directory.appendingPathComponent("vocabulary-import-conflicts-light.png"))
        try render(VocabularyWindowView().environment(idle), theme: .light, size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-window-empty-light.png"))
        try render(VocabularyWindowView().environment(idle), theme: .dark, size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-window-empty-dark.png"))
        settings.hotWords = ["LiveLearn", "WhisperKit", "火山引擎", "Postmortem", "SwiftPM"]
        settings.glossaryLines = ["retry storm=重试风暴", "Postmortem=复盘", "rollback=回滚"]
        try render(VocabularyWindowView().environment(idle), theme: .light, size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-window-light.png"))
        try render(VocabularyWindowView().environment(idle), theme: .dark, size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-window-dark.png"))
        try render(VocabularyWindowView(previewSection: .glossary).environment(idle), theme: .light, size: VocabularyWindowView.minimumSize, to: directory.appendingPathComponent("vocabulary-window-minimum.png"))
        try render(VocabularyWindowView(previewSection: .packs).environment(idle), theme: .light, size: VocabularyWindowView.size, to: directory.appendingPathComponent("vocabulary-window-packs.png"))
        try render(VocabularyWindowView(previewQuery: "不存在的词汇").environment(idle), theme: .light, size: VocabularyWindowView.minimumSize, to: directory.appendingPathComponent("vocabulary-window-no-results.png"))
        // Shortcuts: nothing ships bound, so one row is bound here to show both states.
        settings.requestedSettingsTab = .shortcuts
        settings.setHotKey(KeyCombo(keyCode: kVK_ANSI_H, flags: [.control, .option, .command]), for: .toggleOverlay)
        try render(SettingsView().environment(idle), theme: .light, size: CGSize(width: SettingsView.size.width, height: 900), to: directory.appendingPathComponent("settings-shortcuts-light.png"))
        try render(SettingsView().environment(idle), theme: .dark, size: CGSize(width: SettingsView.size.width, height: 900), to: directory.appendingPathComponent("settings-shortcuts-dark.png"))
        settings.clearHotKeys()
        settings.requestedSettingsTab = .sources

        // Paper menus: the sheets themselves, as they open under a label. The direction menu
        // is the two-column case; the vendor menu has sections; the source menu has ticks.
        try render(menuPreview(idle, kind: .direction), theme: .light, size: CGSize(width: 420, height: 720), to: directory.appendingPathComponent("menu-direction-light.png"))
        try render(menuPreview(idle, kind: .direction), theme: .dark, size: CGSize(width: 420, height: 720), to: directory.appendingPathComponent("menu-direction-dark.png"))
        try render(menuPreview(idle, kind: .vendors), theme: .light, size: CGSize(width: 320, height: 720), to: directory.appendingPathComponent("menu-vendors-light.png"))
        try render(menuPreview(idle, kind: .sources), theme: .light, size: CGSize(width: 360, height: 300), to: directory.appendingPathComponent("menu-sources-light.png"))
    }

    private enum MenuPreviewKind { case direction, vendors, sources }

    private static func importPreview(text: String, library: VocabularyLibrary = VocabularyLibrary(),
                                      fileName: String? = nil, expanded: Bool = false) -> some View {
        VocabularyImportView(text: .constant(text), library: library, fileName: fileName,
                             engineNote: "词汇用于识别与翻译，从下次会话开始应用。不同引擎通过解码提示、词形校准或术语保护使用词汇。",
                             onImport: { _ in }, onCancel: {}, onChooseFile: {}, onLoadFile: { _ in }, previewExpanded: expanded)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .compositingGroup()
            .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(ThemeGround())
    }

    /// A sheet on the ground, as it would sit under its label.
    private static func menuPreview(_ model: AppModel, kind: MenuPreviewKind) -> some View {
        let columns: () -> [PaperMenuColumn]
        switch kind {
        case .direction:
            columns = {
                let source = "en", target = "zh-Hans"
                var from: [PaperMenuItem] = [.row("自动识别", id: "auto", selected: false, keepsOpen: true) {}, .divider()]
                from += LanguageCatalog.common.map { .row($0.name, id: $0.code, selected: $0.code == source, keepsOpen: true) {} }
                from.append(.section("更多语言"))
                from += LanguageCatalog.more.prefix(6).map { .row($0.name, id: $0.code, selected: false, keepsOpen: true) {} }
                var to: [PaperMenuItem] = LanguageCatalog.common.filter { $0.code != source }.map { .row($0.name, id: $0.code, selected: $0.code == target) {} }
                to.append(.section("更多语言"))
                to += LanguageCatalog.more.prefix(6).map { .row($0.name, id: $0.code, selected: false) {} }
                return [PaperMenuColumn(title: "源语言", items: from), PaperMenuColumn(title: "目标语言", items: to)]
            }
        case .vendors:
            columns = {
                var items: [PaperMenuItem] = []
                for group in ChatVendor.groups {
                    items.append(.section(group.title))
                    items += group.vendors.map { v in .row(v.label, id: v.rawValue, selected: v == .deepseek) {} }
                }
                return [PaperMenuColumn(items: items)]
            }
        case .sources:
            columns = {
                [PaperMenuColumn(items: [
                    .check("全部应用（系统声）", id: "all", on: false) {},
                    .divider(),
                    .check("Safari", id: "safari", detail: "正在发声", on: true) {},
                    .check("Zoom", id: "zoom", on: true) {},
                    .check("Music", id: "music", on: false) {},
                    .check("Keynote", id: "keynote", detail: "未运行", on: true) {},
                    .divider("refresh"),
                    .row("刷新列表", keepsOpen: true) {},
                ])]
            }
        }
        let session = PaperMenuSession(columns: columns) { _ in }
        session.highlight = (0, 3)
        return ZStack(alignment: .topLeading) {
            Color.clear
            PaperMenuSheet(session: session)
                .environment(model)
                .padding(.top, 12)
                .padding(.leading, 12)
        }
        .background(ThemeGround())
    }

    private struct ThemeGround: View {
        @Environment(\.theme) private var theme
        var body: some View { theme.ground }
    }

    private static func render<V: View>(_ view: V, theme: LLTheme, size: CGSize?, to url: URL, scale: CGFloat = 2) throws {
        let root = ThemedRoot(forced: theme) { view }
            .frame(width: size?.width, height: size?.height)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .environment(\.staticRender, true)
        let renderer = ImageRenderer(content: root)
        renderer.scale = scale
        if let size { renderer.proposedSize = ProposedViewSize(size) }
        guard let cg = renderer.cgImage else {
            throw NSError(domain: "PreviewRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed for \(url.lastPathComponent)"])
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size ?? CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PreviewRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
        }
        try png.write(to: url)
    }
}

/// A stand-in for what sits behind the overlay: a lecture slide in a video player.
struct VideoBackdrop<Content: View>: View {
    let bright: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .bottom) {
            (bright ? Color(hex: 0xE9E6DF) : Color(hex: 0x2B2E2A))
            VStack(alignment: .leading, spacing: 18) {
                RoundedRectangle(cornerRadius: 2).fill(bright ? Color(hex: 0x1E1C19).opacity(0.7) : Color.white.opacity(0.75)).frame(width: 420, height: 14)
                RoundedRectangle(cornerRadius: 2).fill(bright ? Color(hex: 0x1E1C19).opacity(0.35) : Color.white.opacity(0.4)).frame(width: 620, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(bright ? Color(hex: 0x1E1C19).opacity(0.35) : Color.white.opacity(0.4)).frame(width: 560, height: 8)
                RoundedRectangle(cornerRadius: 2).fill(bright ? Color(hex: 0x1E1C19).opacity(0.35) : Color.white.opacity(0.4)).frame(width: 600, height: 8)
                Spacer()
            }
            .padding(64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            content()
                .padding(.bottom, 48)
        }
    }
}
