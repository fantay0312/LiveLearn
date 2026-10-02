import SwiftUI
import AppKit
import ParticleMath

/// One stable reading surface; the optional history panel sits to its left. Opening the
/// panel changes available width without recreating the transcript's scroll state.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender
    @State private var historyOverride: Bool?
    @State private var historyQuery = ""
    @State private var interaction = ParticleInteraction()
    var previewHistoryVisible: Bool? = nil

    private var idle: Bool { model.sessionState == .idle }
    private var showsHistory: Bool { model.mainPage == .transcript && ((staticRender ? previewHistoryVisible : historyOverride) ?? true) }
    /// Hidden pages stay mounted only while they hold something a page switch must not lose.
    /// A transcript with content (a session, a finished one still on screen, a record being
    /// read) keeps its scroll state; an empty idle one has none, and an unopened vocabulary page
    /// has no search, section or star-map choice yet. Each mounted page costs a window-sized
    /// backing store even at opacity 0 (measured 11–18 MB for the two).
    private var keepsTranscriptMounted: Bool { !model.lanes.isEmpty || model.isViewingRecord || model.sessionState != .idle }
    @State private var vocabularyVisited = false

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = MainWindowLayout.historyWidth(windowWidth: geometry.size.width)
            let contentWidth = geometry.size.width - (showsHistory ? panelWidth : 0)
            VStack(spacing: 0) {
                windowHeader
                if let error = TranslationFeature.shared.lastError {
                    HStack(spacing: 12) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(LLFont.body).foregroundStyle(theme.brick)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 8)
                        if TranslationFeature.shared.canRetry {
                            Button("重试") { TranslationFeature.shared.retryLastOperation() }.buttonStyle(TextButtonStyle())
                        }
                        Button { TranslationFeature.shared.dismissError() } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                            .buttonStyle(GlyphButtonStyle()).accessibilityLabel("关闭翻译操作提示")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 8)
                }
                HStack(spacing: 0) {
                    SidebarView(width: panelWidth, query: $historyQuery)
                        // A line of light between the rail and the page, fading at both ends and
                        // stopping well above the dock, so it never touches the nav orbit.
                        .overlay(alignment: .trailing) {
                            FadingRule(axis: .vertical, ends: .both, fade: LLMetrics.space(7))
                                .padding(.top, LLMetrics.space(2)).padding(.bottom, LLMetrics.space(5))
                        }
                        .frame(width: showsHistory ? panelWidth : 0, alignment: .leading)
                        .opacity(showsHistory ? 1 : 0)
                        .clipped()
                        .allowsHitTesting(showsHistory)
                        .disabled(!showsHistory)
                        .accessibilityHidden(!showsHistory)
                    VStack(spacing: 0) {
                        ZStack {
                            EmptyStateView()
                                .opacity(model.mainPage == .home ? 1 : 0)
                                .allowsHitTesting(model.mainPage == .home)
                                .disabled(model.mainPage != .home)
                                .accessibilityHidden(model.mainPage != .home)
                            if model.mainPage == .transcript || keepsTranscriptMounted {
                                TranscriptView(width: contentWidth)
                                    .opacity(model.mainPage == .transcript ? 1 : 0)
                                    .allowsHitTesting(model.mainPage == .transcript)
                                    .disabled(model.mainPage != .transcript)
                                    .accessibilityHidden(model.mainPage != .transcript)
                            }
                            if model.mainPage == .vocabulary || vocabularyVisited {
                                VocabularyWindowView(embedded: true)
                                    .opacity(model.mainPage == .vocabulary ? 1 : 0)
                                    .allowsHitTesting(model.mainPage == .vocabulary)
                                    .disabled(model.mainPage != .vocabulary)
                                    .accessibilityHidden(model.mainPage != .vocabulary)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .animation(LLMotion.enter(reduceMotion, 0.18), value: idle)
                        if !idle && (model.mainPage == .transcript || (model.mainPage == .vocabulary && model.isActive)) {
                            // The horizon: no card, the transport on the ground under a fading
                            // rule. On the records page it spans exactly the reading block, so the
                            // marks sit in the timestamp gutter and the words start on the text
                            // column; on the vocabulary page it spans the content column under the
                            // search, and its rule is that page's only horizontal line.
                            let onRecords = model.mainPage == .transcript
                            let vocabularyLeading = VocabularyPageMetrics.railWidth + VocabularyPageMetrics.contentLeading
                            let span = onRecords ? ReadingColumn.width(in: contentWidth)
                                : max(0, contentWidth - vocabularyLeading - VocabularyPageMetrics.contentTrailing)
                            TopBar(availableWidth: span)
                                .frame(width: span)
                                .padding(.leading, onRecords ? ReadingColumn.leading(in: contentWidth) : vocabularyLeading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, LLMetrics.space(1))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(LLMotion.enter(reduceMotion || staticRender, 0.24), value: showsHistory)
                MainNavigationDock(openRecords: openRecords, goHome: returnHome)
                    .padding(.bottom, 16).padding(.top, 8)
            }
            .background {
                ZStack {
                    theme.ground
                    if theme.isDark {
                        // The stars, and on Home the dust over them: one GPU layer when the
                        // window is live, the two Canvas views otherwise.
                        AmbientSky(immersive: model.mainPage == .home && !model.isActive, starsActive: model.mainPage == .home,
                                   dustIntensity: model.mainPage == .home ? (model.isActive ? 0.62 : 1) : nil,
                                   keepOut: Self.skyKeepOut(on: model.mainPage, historyWidth: showsHistory ? panelWidth : 0,
                                                            window: geometry.size),
                                   renderer: .metal)
                    }
                    if model.settings.showBackgroundScene && model.mainPage == .home && !model.isActive {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                ExplorationBackdrop(immersive: true)
                                    .frame(width: min(400, geometry.size.width * 0.38), height: 260)
                                    .opacity(theme.isDark ? 0.25 : 0.16)
                                    .mask(RadialGradient(colors: [.black, .clear], center: .center, startRadius: 70, endRadius: 205))
                                    .allowsHitTesting(false)
                            }
                            .padding(.trailing, 16).padding(.bottom, 64)
                        }
                    }
                }
            }
            .background {
                if !staticRender {
                    // Under the settings modal the sky is paused and blurred: pointer moves over
                    // the backdrop must not schedule displacement work for it.
                    ParticleInputSurface(interaction: interaction, enabled: theme.isDark && model.mainPage == .home && !reduceMotion
                                         && !UnifiedSettingsPresentation.shared.isPresented)
                }
            }
        }
        .coordinateSpace(name: "particle-scene")
        .environment(\.particleInteraction, interaction)
        .modifier(SettingsModalHost())
        .ignoresSafeArea()
        .frame(minWidth: LLMetrics.minWindow.width, minHeight: LLMetrics.minWindow.height)
        .onChange(of: model.mainPage) { _, page in
            // Mounted pages retain their state, but hidden fields must never retain input.
            NSApp.mainWindow?.makeFirstResponder(nil)
            if page == .transcript { historyOverride = nil }
            if page == .vocabulary { vocabularyVisited = true }
        }
        .onChange(of: model.openHomeRequest) { _, _ in historyOverride = false }
    }

    private var windowHeader: some View {
        HStack(spacing: 12) {
            ParticleWordmark(renderer: .metal)
            historyToggle
                .opacity(model.mainPage == .transcript ? 1 : 0)
                .disabled(model.mainPage != .transcript)
                .allowsHitTesting(model.mainPage == .transcript)
                .accessibilityHidden(model.mainPage != .transcript)
            Spacer()
        }
        .padding(.leading, LLMetrics.trafficLightInset + 12).padding(.trailing, 16)
        .frame(height: 48)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }

    /// The directory toggle is a word, like the navigation under it, with no symbol and no hover
    /// plate, drawn as 字幕 / 锁定 on the horizon are (`TextToggleButtonStyle`): `ink` with a
    /// star point stamped under it while the directory is open, `ink3` (lifting to `ink2` under
    /// the pointer) while it is closed. It stays a button that names its action, so VoiceOver
    /// keeps its label and value and ⌘⇧L stays on it.
    private var historyToggle: some View {
        Button("目录", action: toggleHistory)
            .buttonStyle(TextToggleButtonStyle(on: showsHistory))
            .accessibilityLabel(showsHistory ? "收起记录栏" : "显示记录栏")
            .accessibilityValue(showsHistory ? "展开" : "收起")
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .help(showsHistory ? "收起记录目录 · ⌘⇧L" : "展开记录目录 · ⌘⇧L")
    }

    /// What the sky's stars keep off on the pages Home's composition does not govern, in window
    /// points: the records rail with its search while the directory is open (`historyWidth` 0
    /// when closed); on the vocabulary page its rail — the legend of the map's two kinds of
    /// star, where a stray grain beside the 热词 point reads as the 术语 binary — and the top
    /// line with the search and 星图 / 列表, which sits on the records rail's header row. Rails
    /// run from under the header to the dock.
    static func skyKeepOut(on page: MainPage, historyWidth: CGFloat, window: CGSize) -> SkyKeepOut {
        let top = HomeComposition.headerHeight, bottom = window.height - HomeComposition.dockHeight
        switch page {
        case .home:
            return SkyKeepOut()
        case .transcript:
            return historyWidth > 0 ? SkyKeepOut([CGRect(x: 0, y: top, width: historyWidth, height: bottom - top)]) : SkyKeepOut()
        case .vocabulary:
            let rail = VocabularyPageMetrics.railWidth
            return SkyKeepOut([CGRect(x: 0, y: top, width: rail, height: bottom - top),
                               CGRect(x: rail, y: top, width: window.width - rail,
                                      height: SidebarView.headerTop + VocabularyPageMetrics.lineHeight)])
        }
    }

    private func toggleHistory() {
        guard model.mainPage == .transcript else { return }
        if showsHistory { NSApp.keyWindow?.makeFirstResponder(nil) }
        historyOverride = !showsHistory
    }

    private func openRecords() {
        model.requestRecords()
        historyOverride = true
    }

    private func returnHome() {
        model.requestHome()
        historyOverride = false
    }

}

enum MainWindowLayout {
    static func historyWidth(windowWidth: CGFloat) -> CGFloat {
        min(304, max(264, windowWidth * 0.25))
    }
}
