import SwiftUI

private struct SettingsInteractionEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

/// The leading gutter of the page column (`LiveLearnSettingsPage.contentGutter`), handed down
/// by whoever knows the pane's width: `SettingsView` in the host, the 文字翻译 content in the
/// helper. 24 — the minimum — outside a pane (a page rendered on its own).
private struct SettingsContentGutterKey: EnvironmentKey {
    static let defaultValue: CGFloat = 24
}

extension EnvironmentValues {
    var settingsInteractionEnabled: Bool {
        get { self[SettingsInteractionEnabledKey.self] }
        set { self[SettingsInteractionEnabledKey.self] = newValue }
    }
    var settingsContentGutter: CGFloat {
        get { self[SettingsContentGutterKey.self] }
        set { self[SettingsContentGutterKey.self] = newValue }
    }
}

struct SettingsControlPreview {
    var hovered = false
    var pressed = false
    var reduceMotion = false
}

enum SettingsMode: String, CaseIterable, Identifiable {
    case standard, developer
    var id: String { rawValue }
    /// The rail foot's word toggle, and the line under it. The toggle names the mode it turns
    /// on — a word that is on or off, like 字幕 and 锁定 — so standard mode needs no name of its
    /// own on screen.
    static let toggleTitle = "开发者模式"
    static let toggleNote = "显示全部设置与调试选项"
    var isDeveloper: Bool { self == .developer }
}

/// Shared by the host and the bundled translation settings renderer.
///
/// `script/prepare_translation_runtime.py` concatenates this file into the helper's
/// `EasydictApp.swift`, so everything here is SwiftUI + Foundation + CoreGraphics only (no app
/// theme, font or motion modules) and must compile for the helper's macOS 13 / Swift 5 target.
/// Both processes draw the same sidebar, the same star rail and the same sky from this one file,
/// which is what keeps the hand-off to the 文字翻译 panel invisible.
enum LiveLearnSettingsPage: String, CaseIterable, Identifiable {
    case sources, language, engine, localModels, appearance, shortcuts
    case privacy, diagnostics, theme, textTranslation, browserExtension, dictation, modules

    var id: String { rawValue }
    static let windowSize = CGSize(width: 1080, height: 740)
    static let sidebarWidth: CGFloat = 176
    /// The reading measure of every settings page, in both processes: the content column is this
    /// wide wherever it sits (`contentGutter`), the caption-appearance page included; only its
    /// live caption stage runs wider, centred on the same axis.
    ///
    /// 576 and not more: the narrowest card `modalRect` can produce is 825 pt (the 960 pt minimum
    /// window, which `RootView`'s `minWidth` and `.windowResizability(.contentSize)` make the
    /// floor). 176 + 24 + 576 = 776 is 1 pt clear of the close button's 48 pt corner column (its
    /// frame starts at 825 − 48 = 777), so the right rag never runs under the ✕ at any reachable
    /// size — that collision is what judge #2's 字幕外观 fix removed. It also leaves room for a
    /// legacy (always-on) scroller: 649 − 15 − 48 = 586 ≥ 576, so the measure never clamps and the
    /// caption-appearance page cannot split into two rags. `SettingsModalHostTests` pins both.
    static let contentMeasure: CGFloat = 576
    /// The close column: the ✕'s 32 pt square and its 16 pt inset from the card's right edge.
    static let closeColumn: CGFloat = 48
    /// The centre line of the brand "LiveLearn" at the top of the rail. The ✕ sits on it, so the
    /// card's two corners start on one line.
    static let brandLineCenterY: CGFloat = 41

    /// Leading gutter of the content column in a page pane `pane` points wide (round 12): the
    /// measure is centred in the pane, so the page has one axis and no dead band piles up at the
    /// right — 164 pt either side on the 1080 pt card, 131 on the default 1014 pt one. Never
    /// less than 24, and never so much that the rag reaches into the ✕'s corner column: on the
    /// 825 pt minimum card (pane 649) centring would put the rag at 788, under the ✕, so the
    /// gutter stops at 25 and the rag meets the ✕'s column at 777 without entering it. Both
    /// processes use it, so 文字翻译 keeps the host pages' left edge.
    static func contentGutter(pane: CGFloat) -> CGFloat {
        let free = pane - contentMeasure
        return max(24, min(free / 2, free - closeColumn))
    }
    /// Height of the sidebar list (group labels and rows) that the rail canvas covers.
    static let railListHeight: CGFloat = listHeight(in: .developer)
    static let sidebarHeadingSpacing: CGFloat = 0

    static func pages(in mode: SettingsMode) -> [Self] {
        let common: [Self] = [.sources, .language, .appearance,
                              .modules, .dictation, .textTranslation, .browserExtension,
                              .engine, .localModels, .theme, .shortcuts, .privacy]
        return mode.isDeveloper ? common + [.diagnostics] : common
    }

    static func listHeight(in mode: SettingsMode) -> CGFloat {
        pages(in: mode).reduce(0) { $0 + ($1.group == nil ? 0 : 36) + 32 }
    }

    static func modalRect(in bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(windowSize.width, max(0, bounds.width - max(64, bounds.width * 0.14))).rounded(.down),
                          height: min(windowSize.height, max(0, bounds.height - max(64, bounds.height * 0.12))).rounded(.down))
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func railCenterY(_ page: LiveLearnSettingsPage, mode: SettingsMode = .developer) -> CGFloat {
        var y: CGFloat = 0
        for candidate in pages(in: mode) {
            if candidate.group != nil { y += 36 }
            if candidate == page { return y + 16 }
            y += 32
        }
        return 16
    }

    var title: String {
        switch self {
        case .sources: return "音源与设备"
        case .language: return "语言"
        case .engine: return "引擎"
        case .localModels: return "本地模型"
        case .appearance: return "字幕外观"
        case .shortcuts: return "快捷键"
        case .privacy: return "隐私与记录"
        case .diagnostics: return "诊断"
        case .theme: return "主题"
        case .textTranslation: return "文字翻译"
        case .browserExtension: return "网页翻译"
        case .dictation: return "语音输入"
        case .modules: return "功能管理"
        }
    }

    var group: String? {
        switch self {
        case .modules: return "翻译与输入"
        case .engine: return "服务与模型"
        case .theme: return "应用偏好"
        case .diagnostics: return "开发者"
        default: return nil
        }
    }

    var shortcut: KeyEquivalent? {
        let keys: [Self: Character] = [.sources: "1", .language: "2", .engine: "3", .localModels: "4",
            .appearance: "5", .shortcuts: "6", .privacy: "7", .diagnostics: "8", .theme: "9", .browserExtension: "0"]
        return keys[self].map { KeyEquivalent($0) }
    }
}

/// Colour literals equal to the host's stellar / wilds theme tokens, so the helper renders the
/// same pixels without the theme module.
struct RailInk {
    let ink: Color
    let ink2: Color
    let ink3: Color
    /// Points of light: #D8E9F2 (the navigation stars) / the wilds accent #28644E.
    let star: Color
    /// The theme hairline at its own alpha (#D8DFEB @ 0.17 / #5E775B @ 0.24).
    let rule: Color

    static let dark = RailInk(
        ink: Color(red: 0.949, green: 0.953, blue: 0.961),
        ink2: Color(red: 0.725, green: 0.741, blue: 0.776),
        ink3: Color(red: 0.573, green: 0.600, blue: 0.647),
        star: Color(red: 0.847, green: 0.914, blue: 0.949),
        rule: Color(red: 0.847, green: 0.875, blue: 0.922).opacity(0.17))

    static let light = RailInk(
        ink: Color(red: 0.149, green: 0.235, blue: 0.196),
        ink2: Color(red: 0.306, green: 0.380, blue: 0.325),
        ink3: Color(red: 0.384, green: 0.427, blue: 0.349),
        star: Color(red: 0.157, green: 0.392, blue: 0.306),
        rule: Color(red: 0.369, green: 0.467, blue: 0.357).opacity(0.24))

    static func of(dark isDark: Bool) -> RailInk { isDark ? dark : light }
}

/// The settings sidebar: a plain-text brand line, then group labels and page
/// names on one left edge (30 pt inside the padded column). The 20 pt gutter left of the names
/// is empty from top to bottom; the `rail` view (seven points of light) lives there and is the
/// only thing that marks the selection. No icons, no fills, no rules between rows.
///
/// The foot (round 12) is one word toggle, 开发者模式, under a rule — the boxed two-segment
/// switch it replaces was the only filled, outlined control in the rail. The list scrolls above
/// the rule and is clipped at it; where the card cuts the list, the cut edge dissolves
/// (`RailScrollEdge`) the way the page column's does, so a short window reads "there is more"
/// instead of silently losing 快捷键 and 隐私与记录. The selected page is always shown clear of
/// that fade: on open, and whenever the selection moves to a row the card cuts.
struct LiveLearnSettingsSidebar<Rail: View>: View {
    let selection: LiveLearnSettingsPage
    let dark: Bool
    let select: (LiveLearnSettingsPage) -> Void
    /// Offscreen renders (ImageRenderer draws no scroll views) ask for a plain list.
    var scrollable = true
    var mode: SettingsMode = .developer
    var setMode: ((SettingsMode) -> Void)? = nil
    @ViewBuilder var rail: (_ selectionIndex: Int) -> Rail
    /// How much list the scroll view hides above and below, each capped at the fade.
    @State private var hidden = RailScrollEdge.Hidden()
    /// Where the list is scrolled to, read only when the selection changes.
    @State private var scrolled = RailScrollEdge.Offset()

    private var ink: RailInk { RailInk.of(dark: dark) }
    private var selectionIndex: Int { LiveLearnSettingsPage.allCases.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LiveLearn").font(.system(size: 12, weight: .medium)).kerning(0.4)
                .foregroundStyle(ink.ink3)
                .frame(height: 26, alignment: .leading)
                .padding(.leading, 30).padding(.top, LiveLearnSettingsPage.brandLineCenterY - 13)
                .padding(.bottom, LiveLearnSettingsPage.sidebarHeadingSpacing)
            ScrollViewReader { proxy in
                // The window is the height left between the brand line and the foot's rule. A
                // reader, not a measured state, so the offscreen render and the first live frame
                // agree.
                GeometryReader { geometry in
                    let window = geometry.size.height
                    let content = LiveLearnSettingsPage.listHeight(in: mode)
                    if scrollable {
                        scroller(window: window, content: content, proxy)
                    } else {
                        // ImageRenderer draws no scroll views, so the static render places the
                        // list where the live one opens — at the top, or scrolled just far
                        // enough to show the selected page — and cuts and fades what does not
                        // fit, as the real modal does.
                        let offset = RailScrollEdge.offset(revealing: LiveLearnSettingsPage.railCenterY(selection, mode: mode),
                                                           from: 0, window: window, content: content)
                        Color.clear.overlay(alignment: .top) { list.offset(y: -offset) }.clipped()
                            .mask { RailScrollEdge(hidden: .init(above: offset, below: content - window - offset)) }
                    }
                }
            }
            // The flexible container (minimum 0, priority over the trailing spacer) keeps the
            // list's 460 / 528 pt from pushing the card out of a short frame.
            .layoutPriority(1)
            if let setMode {
                modeToggle(setMode)
            } else {
                Spacer(minLength: 12)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: LiveLearnSettingsPage.sidebarWidth)
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [.clear, ink.rule.opacity(0.65), ink.rule.opacity(0.65), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 0.5)
                .accessibilityHidden(true)
        }
    }

    /// The live list. The mask is there only while the card cuts the list: the rail canvas
    /// redraws 15–30 times a second inside it, and a mask composites every one of those frames
    /// offscreen even when both of its bands are empty (the default window fits the list).
    /// Crossing that line — a resize — rebuilds the scroll view, which then opens on the
    /// selection again (`onAppear` is on both branches).
    @ViewBuilder
    private func scroller(window: CGFloat, content: CGFloat, _ proxy: ScrollViewProxy) -> some View {
        let scroll = ScrollView { list }
            .scrollIndicators(.hidden)
            .modifier(RailScrollEdge.Tracking(hidden: $hidden, offset: scrolled))
            .onAppear { reveal(selection, from: 0, window: window, content: content, proxy) }
            .onChange(of: selection) { value in
                reveal(value, from: scrolled.value, window: window, content: content, proxy)
            }
        if content > window {
            scroll.mask { RailScrollEdge(hidden: hidden) }
        } else {
            scroll
        }
    }

    /// Scrolls `page` clear of both fades when it is not (`RailScrollEdge.offset(revealing:)`),
    /// without animation, as the list always has. `scrollTo` puts one unit point of the row on
    /// the same unit point of the window; this one lands the row's top at `centre − 16 − target`,
    /// i.e. the list at `target`.
    private func reveal(_ page: LiveLearnSettingsPage, from offset: CGFloat, window: CGFloat, content: CGFloat,
                        _ proxy: ScrollViewProxy) {
        let center = LiveLearnSettingsPage.railCenterY(page, mode: mode)
        let target = RailScrollEdge.offset(revealing: center, from: offset, window: window, content: content)
        guard target != offset, window > 32 else { return }
        proxy.scrollTo(page, anchor: UnitPoint(x: 0.5, y: (center - 16 - target) / (window - 32)))
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LiveLearnSettingsPage.pages(in: mode)) { page in
                if let group = page.group {
                    Text(group).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.ink3)
                        .frame(height: 14, alignment: .leading)
                        .padding(.leading, 30)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                }
                RailRow(page: page, selected: selection == page, dark: dark) { select(page) }
                    .id(page)
            }
        }
        .background(alignment: .topLeading) {
            rail(selectionIndex)
                .frame(width: 36, height: LiveLearnSettingsPage.listHeight(in: mode))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The rail foot: a rule from the text column, the word toggle as wide as a rail row (so its
    /// hover light has the rows' shape), and the line that says what the mode adds. Switching
    /// only changes which pages and rows are shown; no configuration is touched.
    ///
    /// The line stands 5 pt under the toggle's row, not 2: the on word's stamped star sits
    /// ≈ 7 pt under the word's ink, and at 2 pt its rays ended 3 pt above the line's ink, so the
    /// star read as a bullet of the line. At 5 its rays end 5 pt clear of the line and the star
    /// belongs to the word; any more and the off word — the foot most people see, with no star —
    /// floats midway between the rule and its own line instead of hanging from it. The 3 pt come
    /// out of the air above (rule 12 → 10) and go back below (bottom 20 → 19), so the rule, and
    /// with it the list's window, stays where it was.
    private func modeToggle(_ change: @escaping (SettingsMode) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RailRule(dark: dark).padding(.leading, 30)
            Toggle(isOn: Binding(get: { mode.isDeveloper }, set: { on in
                NSApp.keyWindow?.makeFirstResponder(nil)
                change(on ? .developer : .standard)
            })) {
                Text(SettingsMode.toggleTitle).font(.system(size: 13))
            }
            .toggleStyle(RailWordToggleStyle(dark: dark))
            .help(SettingsMode.toggleNote)
            .accessibilityHint(SettingsMode.toggleNote)
            .padding(.top, 10)
            Text(SettingsMode.toggleNote).font(.system(size: 11)).foregroundStyle(ink.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30).padding(.top, 5)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 19)
    }
}

/// A word that is on or off in the rail's own grammar (TextToggleStyle's, drawn with `RailInk`
/// so the helper can compile it): on is `ink` with the star point stamped under the word — the
/// mark every on word carries (Home's 字幕, the transport's 字幕 / 锁定) — off rests in full
/// `ink3` with no mark and lifts to `ink2` under the pointer — colour only, never weight — with
/// the rail rows' feathered light and press (`RailRowStyle(toggle:)`). The star is an overlay on
/// the word's own text box, so switching never moves the foot. Laid out like a `RailRow` (word
/// 30 pt in, 28 pt tall), so it shares the rows' edge.
/// VoiceOver reads a switch (`accessibilityRepresentation`, which macOS 13 has; `.isToggle` does
/// not exist there).
private struct RailWordToggleStyle: ToggleStyle {
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 0) {
                configuration.label
                    .overlay(alignment: .bottom) {
                        if configuration.isOn { SettingsStarPoint(dark: dark, stamped: true) }
                    }
                    .padding(.leading, 20)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailRowStyle(selected: configuration.isOn, dark: dark, anchor: .leading, toggle: true))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

/// The rail's rule (and the helper form's): 0.5 pt of the theme rule at 55 %, solid from where
/// the text starts and fading over the last tenth — the host's `SettingsRule` in literal ink.
struct RailRule: View {
    let dark: Bool

    var body: some View {
        let rule = RailInk.of(dark: dark).rule
        LinearGradient(stops: [.init(color: rule.opacity(0.55), location: 0),
                               .init(color: rule.opacity(0.55), location: 0.90),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// The sidebar list's cut edges, dissolved: a mask (nothing painted, the sky behind keeps its
/// brightness) whose top and bottom bands are exactly as tall as the list hidden beyond them,
/// up to `fade`. At rest the first row sits on the top edge and must not dim, so the top band
/// grows with the scroll offset instead of being fixed; scrolled to the end, the bottom band is
/// gone the same way. No band ever pops in or out.
///
/// The cut has to cross a name, or the list still ends as if it were complete: the card can
/// cut it exactly between two rows (the 960 × 600 window cuts it under 主题), and a band laid
/// over one whole row then dims that name evenly to half — which reads as a disabled row, not as
/// "more below". The band is 24 pt, half as tall again as a name's line, so it always reaches
/// into a name (or a group label) and grades it, from full ink at its top to about half at its
/// baseline — at 960 × 600, 主题. The list is clipped at the foot's rule and the band ends on
/// it: nothing is drawn under the rule — the top of the next name, shown dissolving under it,
/// read as clipped text pressed against 开发者模式, not as a scroll edge.
struct RailScrollEdge: View {
    nonisolated static let fade: CGFloat = 24

    struct Hidden: Equatable {
        var above: CGFloat = 0
        var below: CGFloat = 0
    }

    /// The list's scroll offset, for the one moment it is needed (a selection change): a plain
    /// reference, written on every scroll step without re-evaluating the sidebar.
    final class Offset {
        var value: CGFloat = 0
    }

    let hidden: Hidden

    /// The band for `hidden` points of list beyond an edge: nothing at rest, `fade` at most.
    nonisolated static func band(_ hidden: CGFloat) -> CGFloat { min(fade, max(0, hidden)) }

    /// The scroll offset at which the page name centred at `center` (list coordinates) stands
    /// clear of both bands, in a `window` onto a list `content` tall. `offset` itself when the
    /// name already is clear, otherwise the least movement that clears it — so a click on a row
    /// that can be read never scrolls it out from under the pointer, and a page the card cuts
    /// opens just above the fade. The name's line, not the 32 pt row, is what has to clear: 8 pt
    /// either side of the centre.
    nonisolated static func offset(revealing center: CGFloat, from offset: CGFloat, window: CGFloat, content: CGFloat) -> CGFloat {
        let top = center - 8, bottom = center + 8
        let upper = offset + band(offset)
        let lower = offset + window - band(content - window - offset)
        if top >= upper && bottom <= lower { return offset }
        let target = top < upper ? top - fade : bottom - window + fade
        return min(max(0, content - window), max(0, target))
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.band(hidden.above))
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.band(hidden.below))
        }
        .accessibilityHidden(true)
    }

    /// Reads the hidden amounts and the offset from the scroll view (macOS 15's scroll geometry;
    /// the helper's macOS 13 target compiles this file but draws no sidebar, so there it reads
    /// nothing). The amounts are clamped to the fade, so scrolling a long way past it changes no
    /// state; the offset only goes into its reference.
    struct Tracking: ViewModifier {
        @Binding var hidden: Hidden
        let offset: Offset

        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.visibleRect.minY
                } action: { _, value in
                    offset.value = value
                }
                .onScrollGeometryChange(for: Hidden.self) { geometry in
                    Hidden(above: RailScrollEdge.band(geometry.visibleRect.minY),
                           below: RailScrollEdge.band(geometry.contentSize.height - geometry.visibleRect.maxY))
                } action: { _, value in
                    hidden = value
                }
            } else {
                content
            }
        }
    }
}

/// One page name: 13 pt text whose colour is the only state (selected `ink`, otherwise `ink2`).
/// Hover state lives in the style so a pointer sweep re-evaluates one row. The shortcut, help
/// and selected trait sit on the button itself, so assistive technology reads one button per
/// page with its state.
private struct RailRow: View {
    let page: LiveLearnSettingsPage
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(page.title).font(.system(size: 13)).padding(.leading, 20)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(RailRowStyle(selected: selected, dark: dark, anchor: .leading))
        .keyboardShortcut(page.shortcut.map { KeyboardShortcut($0, modifiers: .command) })
        .help(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Shared settings feedback: brighter ink and transient light, then a short, interruptible press.
///
/// `toggle` makes it an on/off word instead of a choice (the rail foot's 开发者模式): `selected`
/// then means on, and off rests in `ink3` and lifts only to `ink2` under the pointer;
/// Differentiate Without Color underlines the on word. Off is full `ink3` at full opacity, as
/// `TextToggleStyle`'s off word is, not the rows' 92 % rest: under the word sits its own 11 pt
/// `ink3` line, and any less and the control reads quieter than its footnote (at 60 % it fell to
/// ≈ 3:1). Size alone (13 over 11) then ranks the two.
struct RailRowStyle: ButtonStyle {
    var selected = false
    var dark: Bool? = nil
    var anchor: UnitPoint = .center
    var toggle = false
    var preview: SettingsControlPreview? = nil

    func makeBody(configuration: Configuration) -> some View {
        RailRowBody(configuration: configuration, selected: selected, dark: dark, anchor: anchor, toggle: toggle, preview: preview)
    }

    private struct RailRowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let dark: Bool?
        let anchor: UnitPoint
        let toggle: Bool
        let preview: SettingsControlPreview?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor
        @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
        @State private var hovering = false

        private var hovered: Bool { enabled && (preview?.hovered ?? hovering) }
        private var pressed: Bool { enabled && (preview?.pressed ?? configuration.isPressed) }
        private var reduceMotion: Bool { preview?.reduceMotion ?? systemReduceMotion }

        private func color(_ ink: RailInk) -> Color {
            guard enabled else { return ink.ink3 }
            if selected { return ink.ink }
            if toggle { return hovered || pressed ? ink.ink2 : ink.ink3 }
            return hovered || pressed ? ink.ink : ink.ink2
        }

        var body: some View {
            let ink = RailInk.of(dark: dark ?? (colorScheme == .dark))
            configuration.label
                .foregroundStyle(color(ink))
                .underline(toggle && selected && withoutColor, color: ink.ink)
                .background {
                    SettingsInteractionLight(color: ink.ink, active: hovered || pressed, pressed: pressed)
                }
                .opacity(enabled ? (pressed ? 0.86 : (hovered || selected || toggle ? 1 : 0.92)) : 0.45)
                .scaleEffect(pressed && !reduceMotion ? 0.96 : 1, anchor: anchor)
                .offset(y: pressed && !reduceMotion ? 1 : 0)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6))
                .animation(reduceMotion || preview != nil ? nil : pressed ? .easeOut(duration: 0.07)
                           : .spring(response: 0.26, dampingFraction: 0.74), value: pressed)
                .animation(reduceMotion || preview != nil ? nil : .easeOut(duration: hovered ? 0.10 : 0.08), value: hovered)
                .onHover { hovering = $0 }
        }
    }
}

struct SettingsInteractionLight: View {
    let color: Color
    let active: Bool
    let pressed: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, geometry.size.height)
            RadialGradient(colors: [color.opacity(pressed ? 0.18 : 0.10), .clear],
                           center: .center, startRadius: 0, endRadius: side / 2)
                .frame(width: side, height: side)
                .scaleEffect(x: geometry.size.width / side, y: 1)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .opacity(active ? 1 : 0)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Seven points of light beside the selected page name. On a selection change each point takes
/// its own curved flight down the gutter to the new row (all have landed within 0.5 s), then
/// keeps drifting on a slow ellipse around the row's centre. Positions are canvas points in a
/// 36 × `railListHeight` canvas whose x 6…24 band never touches a glyph (labels start at 30).
final class SettingsRailMotion {
    static let count = 7
    /// Departure order and orbit size per point; index 0 is the bright star and leaves first.
    static let seeds: [Double] = [0, 0.67, 0.17, 0.5, 1.0, 0.33, 0.83]
    static let depths: [Double] = [0.3, 0.9, 0.1, 0.6, 0.45, 0.8, 0.2]
    static let minX: CGFloat = 6
    static let maxX: CGFloat = 24
    /// Hand-over from the arrival point into the resting drift.
    static let blend = 0.2
    /// The clock policy, read by both processes (host `LuminousMotion`, helper `TimelineView`)
    /// so the two cannot drift apart: 30 Hz while a flight is in the air, 15 Hz for the resting
    /// drift, and a window long enough to cover the slowest point. The real worst case is
    /// 0.47 s (point 4: delay 0.10 + duration 0.37 — the 0.10 + 0.40 pairing the reconciliation
    /// bounds at 0.50 s never actually occurs), 0.67 s with the arrival blend, so 0.7 s leaves
    /// 30 ms of margin. `SettingsRailMotionTests` pins all three numbers.
    static let flightRate = 30.0
    static let restRate = 15.0
    static let flightWindow = 0.7

    private var positions: [CGPoint] = []
    private var lastTime: Double?
    private var motionTime = 0.0
    private var currentSelection: Int?
    private var currentMode: SettingsMode?
    private var flightStart = 0.0
    private var flights: [Flight] = []

    struct Flight {
        let start: CGPoint
        let control1: CGPoint
        let control2: CGPoint
        let end: CGPoint
        let delay: Double
        let duration: Double

        /// Cubic-out: a fast departure and a soft stop, the enter-curve character.
        func point(at age: Double) -> CGPoint {
            let p = min(1, max(0, (age - delay) / duration))
            let q = 1 - p
            let u = 1 - q * q * q, v = 1 - u
            return CGPoint(x: v * v * v * start.x + 3 * v * v * u * control1.x + 3 * v * u * u * control2.x + u * u * u * end.x,
                           y: v * v * v * start.y + 3 * v * v * u * control1.y + 3 * v * u * u * control2.y + u * u * u * end.y)
        }
    }

    static func delay(_ index: Int) -> Double { seeds[index % count] * 0.10 }
    static func duration(_ index: Int) -> Double { 0.34 + Double(index % 3) * 0.03 }

    static func page(_ selection: Int) -> LiveLearnSettingsPage {
        let pages = LiveLearnSettingsPage.allCases
        return pages[min(max(0, selection), pages.count - 1)]
    }

    /// Resting position of point `index` around the selected row at motion time `time`.
    static func target(_ index: Int, selection: Int, time: Double, mode: SettingsMode = .developer) -> CGPoint {
        let seed = seeds[index % count], depth = depths[index % count]
        let angle = Double(index) * 2.399963 + Double(selection) * 1.37 + time * (0.19 + seed * 0.09)
        let rx = index == 0 ? 2.0 : 4 + seed * 4
        let ry = index == 0 ? 3.0 : 7 + depth * 9
        let x = min(maxX, max(minX, 16 + CGFloat(cos(angle) * rx)))
        let y = LiveLearnSettingsPage.railCenterY(page(selection), mode: mode) + CGFloat(sin(angle) * ry)
        return CGPoint(x: x, y: y)
    }

    private static func clampX(_ x: CGFloat) -> CGFloat { min(maxX, max(minX, x)) }

    func sample(time: Double, selection: Int, stationary: Bool = false, mode: SettingsMode = .developer) -> [CGPoint] {
        let t = time.isFinite ? time : 0
        if currentMode != mode { currentSelection = nil; currentMode = mode }
        guard !stationary else {
            positions = (0..<Self.count).map { Self.target($0, selection: selection, time: 0, mode: mode) }
            currentSelection = selection
            flights = []
            motionTime = 0
            flightStart = 0
            lastTime = t
            return positions
        }
        // No catch-up burst after a hidden window or inactive app resumes.
        let delta = min(1.0 / 15, max(0, t - (lastTime ?? t)))
        lastTime = t
        motionTime += delta
        guard let previous = currentSelection, !positions.isEmpty else {
            // First frame: the resting cluster at the current row, no flight on open.
            positions = (0..<Self.count).map { Self.target($0, selection: selection, time: motionTime, mode: mode) }
            currentSelection = selection
            flights = []
            return positions
        }
        if previous != selection {
            currentSelection = selection
            flightStart = motionTime
            flights = positions.indices.map { index in
                let delay = Self.delay(index), duration = Self.duration(index)
                let start = positions[index]
                let end = Self.target(index, selection: selection, time: motionTime + delay + duration, mode: mode)
                let dy = end.y - start.y
                let drift = CGFloat(4 + Self.seeds[index % Self.count] * 4)
                let sign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
                // Points fan sideways inside the gutter before approaching from the other side;
                // control points stay inside x 6…24, so Bézier convexity bounds the whole path.
                let c1 = CGPoint(x: Self.clampX(start.x + sign * drift), y: start.y + 0.35 * dy)
                let c2 = CGPoint(x: Self.clampX(end.x - sign * drift), y: end.y - 0.25 * dy)
                return Flight(start: start, control1: c1, control2: c2, end: end, delay: delay, duration: duration)
            }
        }
        let age = motionTime - flightStart
        positions = positions.indices.map { index in
            guard index < flights.count else { return Self.target(index, selection: selection, time: motionTime, mode: mode) }
            let flight = flights[index]
            if age < flight.delay + flight.duration { return flight.point(at: age) }
            // Ease from the arrival point into the ongoing local drift.
            let mix = min(1, max(0, (age - flight.delay - flight.duration) / Self.blend))
            let target = Self.target(index, selection: selection, time: motionTime, mode: mode)
            return CGPoint(x: flight.end.x + (target.x - flight.end.x) * mix,
                           y: flight.end.y + (target.y - flight.end.y) * mix)
        }
        return positions
    }
}

/// The gated wall clock the translation helper's rail draws from. The host gets this arithmetic from
/// `LuminousMotion`, which banks the time run so far when its gate closes and restarts the reference
/// instant when it opens; the helper cannot import it, so the same two lines live here as a value.
/// Both the points and the twinkle phase read this one number, so neither can jump across a display
/// sleep — DESIGN.md's "Time never jumps on resume", for the second process. A closed gate is not a
/// static render: nothing is reset, the frame is simply held. The gate itself (`SettingsRailPower`)
/// is in `Vendor/Easydict/Integration/UnifiedSettingsShell.swift`, which only the helper compiles —
/// this file stays SwiftUI + Foundation + CoreGraphics.
struct SettingsRailClock {
    private var elapsed = 0.0
    /// The instant the current run began; `nil` means the gate is closed and time is held.
    private var started: Date?

    var running: Bool { started != nil }

    /// The number the rail draws with; constant while the gate is closed.
    func time(_ now: Date) -> Double {
        guard let started else { return elapsed }
        return elapsed + max(0, now.timeIntervalSince(started))
    }

    /// Idempotent: a repeated `true` keeps the run going instead of restarting it, and a
    /// repeated `false` does not bank the pause twice.
    mutating func setRunning(_ running: Bool, at now: Date) {
        guard running != self.running else { return }
        if running { started = now } else { elapsed = time(now); started = nil }
    }
}

/// The rail's canvas: one bright star (halo and four rays) and six faint ones, each twinkling on
/// its own phase. Eight fills, one gradient and one stroke per frame. Under Increase Contrast
/// every alpha is lifted by 0.12. The light theme carries its own, higher alphas: a dark green
/// point on cream paper has far less contrast at 0.88 / 0.50 than a pale one on black, and at
/// the dark values the wilds cluster reads as specks rather than as light. On paper the bright
/// star has no halo (round 12's paper particle rule, as `SettingsStarPoint`): a halo of dark ink
/// on cream prints as a smudge, not as light.
struct SettingsRailCanvas: View {
    let points: [CGPoint]
    let time: Double
    let dark: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, _ in
            let color = RailInk.of(dark: dark).star
            let lift = contrast == .increased ? 0.12 : 0
            let bright = dark ? 0.88 : 1.0, faint = dark ? 0.50 : 0.65
            for (index, point) in points.enumerated() {
                let twinkle = 0.75 + 0.25 * sin(time * 1.25 + Double(index) * 1.7)
                var alpha = min(1, (index == 0 ? bright : faint) * twinkle + lift)
                // Safety net: nothing bright ever sits over a glyph.
                if point.x > 26 { alpha *= 0.10 }
                let radius: CGFloat = index == 0 ? 0.85 : 0.45 + CGFloat(index % 3) * 0.11
                let x = point.x, y = point.y
                if index == 0 {
                    if dark {
                        let halo = CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: halo), with: .radialGradient(Gradient(colors: [color.opacity(alpha * 0.26), .clear]),
                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 4))
                    }
                    var rays = Path()
                    rays.move(to: CGPoint(x: x - 2.2, y: y)); rays.addLine(to: CGPoint(x: x + 2.2, y: y))
                    rays.move(to: CGPoint(x: x, y: y - 2.2)); rays.addLine(to: CGPoint(x: x, y: y + 2.2))
                    context.stroke(rays, with: .color(color.opacity(alpha * 0.55)), lineWidth: 0.5)
                }
                context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A single stamped point of light: the selection mark of segment words, the caption pane strip,
/// presets, theme titles and the helper's tab strip and menus, and the on mark of the rail
/// foot's 开发者模式. It is the rail's index-0 recipe at small scale — a 1.4 pt core, two 0.5 pt
/// rays at ± 2.2 pt and a 4 pt halo, in an 8 pt slot — so the mark beside a word is made of the
/// same substance as the star beside the selected page name; a plain round dot read as a radio
/// button, which is generic UI vocabulary.
///
/// Always placed in a fixed slot or as a fixed-offset overlay so layout never moves. The word
/// strips (`TextSegment`, the 字幕外观 pane strip, the helper's tab strip) and the rail foot's
/// word stamp the point under the word: that drop lives here, in `stamped`, so one value serves
/// all of them. It is measured from the **word's own text box**, never from the button frame —
/// the three strips pad their words differently (28 pt frame / 11 pt vertical / 32 pt frame),
/// so a frame-relative offset put the point 6.75, 8.75 and 11.75 pt under the three words and
/// dropped two of them onto the rule below. Bottom-aligned to the `Text`, the 8 pt slot's centre
/// already sits 4 pt above the text box; +9 puts it 5 pt below the box, i.e. ≈ 6.75 pt under the
/// ink of a 13 pt CJK word, wherever it is stamped. **Attach the overlay to the `Text`, before
/// any padding or `frame`.**
/// Under Increase Contrast the point is plain ink with no halo.
///
/// On paper (round 12's paper particle rule): a crisp forest point with no halo (a halo of dark
/// ink on cream reads as a smudge), a 3.2 pt core and hairline rays at ± 3.4 pt and half
/// strength, so the dot leads instead of reading as a "+" — the "+" of a rail header sits a few
/// points away — and still carries a choice on cream: at 2.2 pt the point had half the visual
/// weight of the dark star and read as print noise at 1×.
///
/// This is the one recipe: the host's `StarMark` wraps this view (adding only the vocabulary's
/// class hue), and `VocabularyKindMark` sizes a lit binary's companion from `core(paper:)`.
/// `Round12FoundationTests` (dark) and `Round12SettingsTests` (paper) pin that the host's mark
/// stays this view, pixel for pixel.
///
/// `scale` draws the whole recipe, slot included, that much larger: the helper's choice menus
/// are their own popover windows, outside the host's 界面大小 scale, and set their rows at
/// 13 × scale — a fixed 8 pt star was the one thing in them that did not grow. Drawn at that
/// size rather than magnified, so the 1.4 pt core stays crisp; everywhere else it is 1.
struct SettingsStarPoint: View {
    let dark: Bool
    /// Under a word (a strip) rather than in a slot beside it.
    var stamped = false
    var scale: CGFloat = 1
    @Environment(\.colorSchemeContrast) private var contrast

    /// The point's diameter at scale 1.
    static func core(paper: Bool) -> CGFloat { paper ? 3.2 : 1.4 }

    var body: some View {
        let ink = RailInk.of(dark: dark)
        let increased = contrast == .increased
        let paper = !dark
        let color = increased ? ink.ink : ink.star
        Canvas { context, size in
            context.scaleBy(x: scale, y: scale)
            let x = size.width / scale / 2, y = size.height / scale / 2
            if !increased && !paper {
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                             with: .radialGradient(Gradient(colors: [color.opacity(0.26), .clear]),
                                                   center: CGPoint(x: x, y: y), startRadius: 0, endRadius: 4))
            }
            let reach: CGFloat = paper ? 3.4 : 2.2
            var rays = Path()
            rays.move(to: CGPoint(x: x - reach, y: y)); rays.addLine(to: CGPoint(x: x + reach, y: y))
            rays.move(to: CGPoint(x: x, y: y - reach)); rays.addLine(to: CGPoint(x: x, y: y + reach))
            context.stroke(rays, with: .color(color.opacity(increased ? 1 : (paper ? 0.5 : 0.55))), lineWidth: 0.5)
            let core = Self.core(paper: paper)
            context.fill(Path(ellipseIn: CGRect(x: x - core / 2, y: y - core / 2, width: core, height: core)),
                         with: .color(color))
        }
        .frame(width: 8 * scale, height: 8 * scale)
        .offset(y: stamped ? 9 * scale : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `PaperMenu`'s grammar without `PaperMenu`: a bare 13 pt label and a 7.5 pt chevron, no plate,
/// no bezel, no system indicator. The helper's form uses it in place of the native pop-up
/// button, which was the last control in the modal that read as a different product. The rows
/// stay the caller's (the helper keeps its flag emoji inside the list, never in the label).
///
/// `.menuStyle(.button)` and not `.borderlessButton`: the borderless style is an
/// `NSPopUpButton` underneath, which takes only the label's *string* — the custom chevron was
/// dropped and AppKit drew its own, larger one on the leading side, so the row read backwards
/// against the host's `PaperMenu`. The button style renders the label view as written; the
/// plain button style removes the bezel and `menuIndicator(.hidden)` the system chevron.
///
/// Round 12: the chevron lifts from `ink3` to `ink2` under the pointer, as `PaperMenu`'s does,
/// so a label already written in `ink` still answers the pointer.
struct SettingsBareMenu<Content: View>: View {
    let title: String
    let dark: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let ink = RailInk.of(dark: dark)
        Menu {
            content()
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(ink.ink)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(hovering && enabled ? ink.ink2 : ink.ink3)
            }
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(RailRowStyle(selected: true, dark: dark))
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// The modal's sky: 140 static points at three brightness levels, pearl and ice, full strength
/// over the sidebar and thinned to 35 % under the content column so text sits on clean black.
/// A plain `Canvas` with no clock; SwiftUI redraws it only on a size change. Draws nothing in
/// the light theme.
///
/// Over the rail the sky keeps its dust but not its glints: none in the gutter (x 12…42, where
/// the seven stars fly), and no bright cross-shaped point anywhere in the rail column — a still
/// glint beside an unselected page name, or after 开发者模式, read as a second selection.
struct SettingsSky: View {
    let dark: Bool

    var body: some View {
        if dark {
            Canvas { context, size in
                let pearl = Color(red: 0.925, green: 0.937, blue: 0.957)
                let ice = Color(red: 0.718, green: 0.827, blue: 0.965)
                for index in 0..<140 {
                    let x = Double((index * 137 + 17) % 997) / 997 * size.width
                    let y = Double((index * 233 + 43) % 991) / 991 * size.height
                    if (12...42).contains(x) { continue }
                    let bright = index % 11 == 0 && x > 176
                    let medium = !bright && index % 3 == 0
                    let diameter: CGFloat = bright ? 1.9 : (medium ? 1.15 : 0.7)
                    let column = x <= 176 ? 1.0 : (x >= 216 ? 0.35 : 1 - (x - 176) / 40 * 0.65)
                    let alpha = (bright ? 0.41 : (medium ? 0.22 : 0.11)) * column
                    let tint = index % 4 == 0 ? ice : pearl
                    if bright {
                        var glint = Path()
                        glint.move(to: CGPoint(x: x - 3.5, y: y)); glint.addLine(to: CGPoint(x: x + 3.5, y: y))
                        glint.move(to: CGPoint(x: x, y: y - 3.5)); glint.addLine(to: CGPoint(x: x, y: y + 3.5))
                        context.stroke(glint, with: .color(tint.opacity(0.10 * column)), lineWidth: 0.5)
                    }
                    context.fill(Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)),
                                 with: .color(tint.opacity(alpha)))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
