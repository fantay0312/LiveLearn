import SwiftUI
import MacAudio
import ParticleMath

/// Centered launch surface. The selected sources stay visible; detailed per-lane controls
/// open in place, leaving the primary action easy to find at every supported window size.
///
/// Home is one instrument on one axis (`HomeComposition`): the core, the capsule 44 pt under
/// its grains, one row (the modes, or the running status), the configuration sentence. The core
/// and the capsule sit where the window size puts them in every state — starting, pausing,
/// failing or changing mode never moves them; what a state adds grows downward.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showingSourceSetup = false
    @State private var showingLanguageSetup = false
    @State private var activationTime: Date?

    /// A failed session's way out. The capsule stays, and starting again from it (⌘↩) is the
    /// retry; the recovery sits under the routes where a start blocker does, its action on the
    /// title's line.
    private var recovery: RecoveryAdvice? {
        model.sessionState == .failed ? model.recoveryAdvice : nil
    }

    /// The state the core shines in: ignited while a session runs, silver while it is paused.
    private var mood: StardustMood {
        model.sessionState == .paused ? .paused : (model.isActive ? .running : .idle)
    }

    var body: some View {
        GeometryReader { geometry in
            let home = HomeComposition(pageWidth: geometry.size.width, pageHeight: geometry.size.height)
            ScrollContainer {
                VStack(spacing: 0) {
                    SessionOrbHero(diameter: home.coreDiameter,
                                   active: model.mainPage == .home && SessionActionAppearance.primary(for: model.sessionState).hasLivingForm,
                                   activationTime: activationTime,
                                   activity: model.sessionState == .paused ? 0.18 : (model.isActive ? 1 : 0.12),
                                   mood: mood)
                        .padding(.top, home.stageTop)
                        .padding(.bottom, home.stageToCapsule)
                    if model.isActive || model.sessionState == .stopping {
                        ActiveHomeSessionView(activationTime: activationTime, onActivate: { activationTime = Date() })
                            .frame(width: 400)
                    } else {
                        idleControls.frame(width: 400)
                    }
                }
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Under the routes, what is wrong comes before the cost note: at the minimum window the
    /// growth air (`HomeComposition.growthAir`) holds a second route, the failure or blocker with
    /// a one-line detail, and the note; a longer detail pushes the note, never the failure,
    /// below the fold.
    private var idleControls: some View {
        VStack(spacing: 0) {
            startButton
            modePicker.padding(.top, HomeComposition.capsuleToRow)
            sourceSummary.padding(.top, HomeComposition.rowToConfiguration)
            VStack(spacing: 8) {
                let advice = recovery ?? model.startBlockerAdvice
                if let advice {
                    RecoveryBanner(advice: advice, compact: true)
                }
                if !model.blueprint.isLocal {
                    Text("云端处理，可能产生费用").font(LLFont.label).foregroundStyle(theme.ink2)
                        .help(model.engineDescription)
                }
                if advice == nil && !model.hasSource {
                    Text("选择音源后开始").font(LLFont.label).foregroundStyle(theme.ink2)
                }
            }
            .padding(.top, 12)
        }
    }

    /// The modes on the dock's own row (`OrbitRow`) over the same orbit the dock draws around its
    /// page: one "where you are" mark, one recipe — a step quieter (`modeStrength`), so the page
    /// location outranks a choice within the page. Increase Contrast keeps it at full strength.
    private var modePicker: some View {
        OrbitRowStack {
            ForEach(SessionMode.allCases) { mode in
                let selected = model.settings.mode == mode
                Button { model.applyMode(mode) } label: {
                    Text(shortTitle(mode))
                        .font(LLFont.bodyStrong)
                        .frame(width: OrbitRow.cell.width, height: OrbitRow.cell.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DockButtonStyle(selected: selected))
                .accessibilityLabel(mode.title).help(mode.note)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background {
            NavigationStarField(selection: SessionMode.allCases.firstIndex(of: model.settings.mode) ?? 0,
                                active: model.mainPage == .home, renderer: .metal, layer: .nebula,
                                strength: theme.raisesContrast ? 1 : NavigationStarField.modeStrength)
        }
    }

    private var sourceSummary: some View {
        VStack(spacing: 0) {
            if model.draftLanes.isEmpty {
                Button("选择音源") { showingSourceSetup = true }.buttonStyle(TextButtonStyle(flush: true))
                    .frame(height: HomeComposition.configurationHeight)
            } else {
                SessionRoutes(routes: model.draftLanes.map { SessionRoutes.Route(source: $0.name, direction: StatusCopy.direction($0.source, $0.target)) },
                              sourceOpen: showingSourceSetup, languageOpen: showingLanguageSetup,
                              sourceAction: { showingLanguageSetup = false; showingSourceSetup = true },
                              languageAction: { showingSourceSetup = false; showingLanguageSetup = true })
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("音源与语言")
        .popover(isPresented: $showingSourceSetup) {
            SessionSourcePopover { showingSourceSetup = false }
        }
        .popover(isPresented: $showingLanguageSetup) {
            SessionLanguagePopover { showingLanguageSetup = false }
        }
    }

    private var startButton: some View {
        SessionControlRail {
        LuminousActionButton(appearance: .start, active: model.mainPage == .home, activationTime: activationTime, renderer: .metal) {
            activationTime = Date()
            model.start()
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!model.canStart || model.isCheckingSource || model.readinessRefreshing)
        .accessibilityLabel("开始翻译")
        // The capsule is the retry and the first thing VoiceOver reaches, so it carries the
        // failure; the banner with its action comes after the modes and the routes.
        .accessibilityHint(recovery.map { "会话失败：\($0.title)" } ?? "")
        .help(model.startBlocker ?? "开始翻译 · ⌘↩")
        }
    }

    private func shortTitle(_ mode: SessionMode) -> String {
        switch mode { case .listen: "收听"; case .converse: "交流"; case .faceToFace: "面对面" }
    }

}

/// Each route read as one sentence on the axis: `Safari ⌄ · 英语 → 中文 ⌄`. Source and direction
/// stay two controls with their own hover, press, labels and popovers; they are simply set
/// together, centred, no wider than the mode row. Values are configuration, so they rest in
/// the quiet ink and come up to full ink when touched or open.
///
/// Two routes (converse) hinge on one dot: sources right-aligned against it, directions
/// left-aligned from it (`RouteHingeLayout`), so the pair reads as one table instead of two
/// sentences centred on their own lengths. One route is exactly the centred sentence. The dot
/// is the status line's: 13 pt in the quiet ink, one separator mark on Home.
struct SessionRoutes: View {
    struct Route {
        let source: String
        let direction: String
    }

    let routes: [Route]
    var sourceOpen = false
    var languageOpen = false
    let sourceAction: () -> Void
    let languageAction: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        RouteHingeLayout {
            ForEach(routes.indices, id: \.self) { index in
                let route = routes[index]
                Button(action: sourceAction) {
                    Text(route.source).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(RouteButtonStyle(open: sourceOpen))
                .accessibilityLabel("\(route.source)音源").help("更改音源")
                Text("·").font(LLFont.body).foregroundStyle(HomeInk(theme).quiet).accessibilityHidden(true)
                Button(action: languageAction) {
                    Text(route.direction).lineLimit(1)
                }
                .buttonStyle(RouteButtonStyle(open: languageOpen))
                .accessibilityLabel("\(route.source)语言").accessibilityValue(route.direction).help("更改语言方向")
            }
        }
    }
}

/// The routes' geometry (`SessionRoutes`). Subviews come in threes — source, dot, direction —
/// one triple per route, each route on its own 30 pt line, 4 pt apart. Every dot sits on one
/// column; sources end `spacing` before it (right-aligned), directions start `spacing` after it
/// (left-aligned). The block is the mode row's width (`maxWidth`), centred on Home's axis, and
/// nothing reaches past it: the sources give way first, truncating in the middle, down to
/// `sourceFloor`; then the directions truncate.
///
/// A single route is exactly the centred sentence. Two hinge on the axis itself whenever each
/// column fits its half of the band; otherwise the dot slides only as far as the longer column
/// needs, never truncating what the band could hold.
struct RouteHingeLayout: Layout {
    var spacing: CGFloat = 10
    var lineHeight: CGFloat = HomeComposition.configurationHeight
    var lineSpacing: CGFloat = 4
    /// The mode row's width: no sentence reaches past it.
    var maxWidth: CGFloat = OrbitRow.size.width
    /// The narrowest a source gets before the directions give way: whole built-in names
    /// (Safari ⌄ / 麦克风 ⌄ / 系统声 ⌄, 50–56 pt) and a readable middle-truncated app name. Below
    /// it a long language pair left the source a bare chevron, under the 24 pt hit area.
    var sourceFloor: CGFloat = 72

    /// The block's size and each subview's frame in it, for subviews of ideal `sizes`.
    static func arrange(_ sizes: [CGSize], spacing: CGFloat, lineHeight: CGFloat, lineSpacing: CGFloat,
                        maxWidth: CGFloat, sourceFloor: CGFloat = 72) -> (size: CGSize, frames: [CGRect]) {
        let routes = sizes.count / 3
        var frames = sizes.map { _ in CGRect.zero }
        guard routes > 0 else { return (.zero, frames) }
        func widest(_ column: Int) -> CGFloat {
            (0..<routes).map { sizes[$0 * 3 + column].width }.max() ?? 0
        }
        let dot = widest(1)
        let room = max(0, maxWidth - 2 * spacing - dot)
        let directions = min(widest(2), room - min(widest(0), sourceFloor, room))
        let sources = min(room - directions, widest(0))
        // The dot's offset from the axis. Both bounds hold at once, because the columns and
        // their gaps never exceed the band.
        let half = maxWidth / 2
        let hinge = routes == 1 ? (sources - directions) / 2
            : min(max(0, sources + spacing + dot / 2 - half), half - directions - spacing - dot / 2)
        let dotX = half + hinge - dot / 2
        for route in 0..<routes {
            let top = CGFloat(route) * (lineHeight + lineSpacing)
            func frame(_ index: Int, x: CGFloat, width: CGFloat) -> CGRect {
                let height = sizes[index].height
                return CGRect(x: x, y: top + (lineHeight - height) / 2, width: width, height: height)
            }
            let source = min(sizes[route * 3].width, sources)
            frames[route * 3] = frame(route * 3, x: dotX - spacing - source, width: source)
            frames[route * 3 + 1] = frame(route * 3 + 1, x: dotX + (dot - sizes[route * 3 + 1].width) / 2,
                                          width: sizes[route * 3 + 1].width)
            frames[route * 3 + 2] = frame(route * 3 + 2, x: dotX + dot + spacing,
                                          width: min(sizes[route * 3 + 2].width, directions))
        }
        let height = CGFloat(routes) * lineHeight + CGFloat(routes - 1) * lineSpacing
        return (CGSize(width: maxWidth, height: height), frames)
    }

    private func arrange(_ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        Self.arrange(subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing, lineHeight: lineHeight,
                     lineSpacing: lineSpacing, maxWidth: maxWidth, sourceFloor: sourceFloor)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews).size
    }

    /// The dots' column, for the status line to stand on (`HorizontalAlignment.routeHinge`).
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .routeHinge else { return nil }
        let block = arrange(subviews)
        guard block.frames.count > 1 else { return nil }
        return bounds.minX + (bounds.width - block.size.width) / 2 + block.frames[1].midX
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let block = arrange(subviews)
        let dx = (bounds.width - block.size.width) / 2, dy = (bounds.height - block.size.height) / 2
        for (subview, frame) in zip(subviews, block.frames) {
            subview.place(at: CGPoint(x: bounds.minX + dx + frame.minX, y: bounds.minY + dy + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}

extension HorizontalAlignment {
    private enum RouteHinge: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[HorizontalAlignment.center] }
    }

    /// The column Home's separator dots stand on: the routes' dot (`RouteHingeLayout`), and the
    /// status line's dot, which `HingedLines` moves onto it when the two nearly meet. A view that
    /// marks no dot answers its centre.
    static let routeHinge = HorizontalAlignment(RouteHinge.self)
}

/// A configuration value in PaperMenu's grammar: the value, then a 7.5 pt chevron. No hover
/// block in either theme — the ink comes up instead (value → ink, chevron → the value's ink),
/// and stays up while its popover is open.
private struct RouteButtonStyle: ButtonStyle {
    var open = false

    func makeBody(configuration: Configuration) -> some View { RouteBody(configuration: configuration, open: open) }

    private struct RouteBody: View {
        let configuration: Configuration
        let open: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let ink = HomeInk(theme)
            let lit = enabled && (open || hovering || configuration.isPressed)
            HStack(spacing: 4) {
                configuration.label.font(.system(size: 14))
                    .foregroundStyle(enabled ? (lit ? ink.strong : ink.value) : theme.inkDisabled)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(lit ? ink.value : ink.quiet)
            }
            .frame(minHeight: HomeComposition.configurationHeight)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(LLMotion.hover(reduceMotion), value: lit)
        }
    }
}
