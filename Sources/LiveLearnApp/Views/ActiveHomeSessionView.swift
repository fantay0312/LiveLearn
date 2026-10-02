import SwiftUI
import SessionDomain
import ParticleMath

/// The active session stays on the home surface. Reading its transcript is an explicit
/// navigation action, and neither entering vocabulary nor returning home stops capture.
///
/// It keeps idle Home's shape: the capsule in the same place (Stop hangs beside it), the status
/// line in the mode row's slot, the routes as the same centred sentences below (`HingedLines`
/// sets the status dot on the routes' when the two nearly meet).
struct ActiveHomeSessionView: View {
    var activationTime: Date? = nil
    var onActivate: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @State private var showingSourceSetup = false

    private var starting: Bool { model.sessionState == .preparing || model.sessionState == .connecting }
    private var windingDown: Bool { model.sessionState == .draining || model.sessionState == .stopping }
    private var paused: Bool { model.sessionState == .paused }

    var body: some View {
        VStack(spacing: 0) {
            controls
            HingedLines(spacing: HomeComposition.rowToConfiguration) {
                SessionStatusLine()
                    .frame(height: HomeComposition.rowHeight)
                SessionRoutes(routes: model.lanes.map {
                                  SessionRoutes.Route(source: $0.configuration.source.displayName,
                                                      direction: StatusCopy.direction($0.configuration.sourceLanguage, $0.configuration.targetLanguage))
                              },
                              sourceOpen: showingSourceSetup, languageOpen: showingSourceSetup,
                              sourceAction: { showingSourceSetup = true }, languageAction: { showingSourceSetup = true })
                .disabled(starting || windingDown || model.isReconfiguringSession)
                .popover(isPresented: $showingSourceSetup) {
                    ActiveSessionSourceEditor(selection: SessionSourceSelection(model: model))
                        .environment(model).environment(\.theme, theme)
                }
            }
            .padding(.top, HomeComposition.capsuleToRow)
            if let advice = model.recoveryAdvice { RecoveryBanner(advice: advice, compact: true).padding(.top, 12) }
        }
    }

    private var controls: some View {
        SessionControlRail {
                LuminousActionButton(appearance: .primary(for: model.sessionState),
                                     active: model.mainPage == .home, activationTime: activationTime, renderer: .metal) {
                    onActivate()
                    paused ? model.resume() : model.pause()
                }
                LuminousActionButton(appearance: .stop, active: model.mainPage == .home, renderer: .metal) {
                    onActivate()
                    model.stop()
                }
                .disabled(windingDown)
            }.disabled(model.isReconfiguringSession)
    }
}

/// `正在翻译 · 0:46   CC 字幕`: the state, its age and the caption switch as one centred line,
/// its dot marked for `HingedLines`.
struct SessionStatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let ink = HomeInk(theme)
        return HStack(spacing: 28) {
            HStack(spacing: 8) {
                Text(title).font(LLFont.body).foregroundStyle(ink.value)
                Text("·").font(LLFont.body).foregroundStyle(ink.quiet).accessibilityHidden(true)
                    .alignmentGuide(.routeHinge) { $0[HorizontalAlignment.center] }
                SessionAge(color: ink.quiet)
            }
            captionToggle
        }
    }

    private var captionToggle: some View {
        @Bindable var model = model
        return Toggle("字幕", isOn: $model.overlayVisible)
            .toggleStyle(CaptionWordToggleStyle())
            .help(model.overlayVisible ? model.overlayCloseHelp : "显示字幕，不会自动开始或继续会话")
    }

    private var title: String {
        switch model.sessionState {
        case .preparing: "正在准备"
        case .connecting: "正在连接"
        case .paused: "已暂停"
        case .reconnecting: "正在重连"
        case .draining, .stopping: "正在收尾"
        case .degraded: "部分音源异常"
        default: "正在翻译"
        }
    }
}

/// The running status over the routes, each line centred on Home's axis — until their dots
/// nearly meet: a status dot within `snap` of the routes' hinge (`HorizontalAlignment.routeHinge`)
/// moves onto it, and the lines read as one table. Two dots a near miss apart look like an
/// error; a clear offset (a converse pair hinged on the axis) reads as two kinds of line, and
/// stays.
///
/// `snap` holds a single short route (Safari, 系统声) running and paused alike: its dot sits
/// 13.5 pt from 正在翻译's and 20.5 pt from the shorter 已暂停's, so at 16 every pause brought the
/// near miss back and moved the status dot 20 pt. A converse pair on the axis stays 33–40 pt
/// off, a slid pair some 60.
struct HingedLines: Layout {
    var spacing: CGFloat
    var snap: CGFloat = 24

    /// How far the first line moves, for each line's dot measured from its own centre.
    static func shift(status: CGFloat, routes: CGFloat, snap: CGFloat) -> CGFloat {
        abs(routes - status) <= snap ? routes - status : 0
    }

    private func lines(_ subviews: Subviews, _ proposal: ProposedViewSize) -> [(size: CGSize, dot: CGFloat)] {
        subviews.map { subview in
            let d = subview.dimensions(in: ProposedViewSize(width: proposal.width, height: nil))
            return (CGSize(width: d.width, height: d.height), d[.routeHinge] - d.width / 2)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, proposal)
        return CGSize(width: lines.map(\.size.width).max() ?? 0,
                      height: lines.map(\.size.height).reduce(0, +) + spacing * CGFloat(max(0, lines.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = lines(subviews, proposal)
        let shift = lines.count > 1 ? Self.shift(status: lines[0].dot, routes: lines[1].dot, snap: snap) : 0
        var y = bounds.minY
        for (index, (subview, line)) in zip(subviews, lines).enumerated() {
            subview.place(at: CGPoint(x: bounds.midX - line.size.width / 2 + (index == 0 ? shift : 0), y: y),
                          proposal: ProposedViewSize(line.size))
            y += line.size.height + spacing
        }
    }
}

/// The session's age on the status line. Its own view because `elapsedNs` ticks every second:
/// read here, a tick re-evaluates this text alone, not the column with its two capsules and
/// the routes (the same confinement as `SessionClock` in the top bar and the menu).
private struct SessionAge: View {
    let color: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(StatusCopy.clock(model.elapsedNs)).font(LLFont.body.monospacedDigit()).foregroundStyle(color)
    }
}

/// The caption switch as a word: a quiet `CC` glyph (no box) and `字幕`, full ink when captions
/// show and quiet when they do not, with the app's star point stamped under the word when on —
/// the mark every chosen word carries. Differentiate Without Color adds the on-state rule the
/// text toggles use. Still a toggle to assistive technology, with its on / off value.
///
/// `CC` is set as a glyph, not as text of the line: 12 pt medium capitals, tracked, centred on
/// the ideographs' box rather than on their baseline — at 11 pt on the baseline its capitals
/// were 70 % of 字幕's height and read as a lowercase "cc".
struct CaptionWordToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { CaptionWordToggle(configuration: configuration) }

    private struct CaptionWordToggle: View {
        let configuration: Configuration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            let ink = HomeInk(theme)
            let on = configuration.isOn
            let lit = on || (enabled && hovering)
            Button { configuration.isOn.toggle() } label: {
                HStack(alignment: .center, spacing: 4) {
                    Text("CC").font(.system(size: 12, weight: .medium)).tracking(0.6)
                        .foregroundStyle(lit ? ink.value : ink.quiet)
                    configuration.label.font(LLFont.body)
                        .foregroundStyle(lit ? ink.strong : ink.quiet)
                        .underline(withoutColor && on, color: theme.ink)
                        .starMarked(on)
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .onHover { hovering = $0 }
            .animation(LLMotion.hover(reduceMotion), value: lit)
            .accessibilityLabel("字幕")
            .accessibilityValue(on ? "开" : "关")
            .accessibilityAddTraits(.isToggle)
        }
    }
}
