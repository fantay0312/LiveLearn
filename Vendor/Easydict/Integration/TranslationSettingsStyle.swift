// Settings-only presentation. Easydict owns every value and action. GPL-3.0.
import SwiftUI

enum TranslationSettingsPalette {
    static let ground = Color(red: 0.012, green: 0.016, blue: 0.020)
    static let surface = Color(red: 0.052, green: 0.063, blue: 0.078)
    static let silver = Color(red: 0.875, green: 0.91, blue: 0.97)
    static let lightGround = Color(red: 243.0 / 255, green: 239.0 / 255, blue: 223.0 / 255)
    static let lightSurface = Color(red: 250.0 / 255, green: 247.0 / 255, blue: 235.0 / 255)
    static let lightInk = Color(red: 38.0 / 255, green: 60.0 / 255, blue: 50.0 / 255)
    static let lightAccent = Color(red: 0.157, green: 0.392, blue: 0.306)

    static func ink2(dark: Bool) -> Color { RailInk.of(dark: dark).ink2 }
    static func ink3(dark: Bool) -> Color { RailInk.of(dark: dark).ink3 }
    static func rule(dark: Bool) -> Color { RailInk.of(dark: dark).rule }
    static func fill(dark: Bool) -> Color {
        dark ? Color(red: 0.847, green: 0.875, blue: 0.922).opacity(0.055)
             : Color(red: 0.22, green: 0.42, blue: 0.325).opacity(0.07)
    }
}

/// The host's row rule; one recipe (`RailRule`, in the shared navigation file) for both.
struct TranslationSettingsRule: View {
    let dark: Bool

    var body: some View { RailRule(dark: dark) }
}

/// The form of every embedded page, on the host's column: the 576 pt measure at the pane's
/// gutter (`settingsContentGutter`, handed down by `TranslationSettingsContent`), so 文字翻译
/// keeps the host pages' left edge when the sidebar switches to it.
struct TranslationSettingsFormStyle: FormStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.settingsContentGutter) private var gutter

    private var dark: Bool { colorScheme == .dark }

    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 15.0, *) {
            ScrollView {
                Group(sections: configuration.content) { sections in
                    VStack(alignment: .leading, spacing: 32) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                if !section.header.isEmpty {
                                    ForEach(section.header) { $0 }
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.bottom, 6)
                                        .foregroundStyle(TranslationSettingsPalette.ink2(dark: dark))
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(section.content) { row in
                                        if row.id != section.content.first?.id {
                                            TranslationSettingsRule(dark: dark)
                                        }
                                        row.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                            .padding(.vertical, 10)
                                    }
                                }
                                if !section.footer.isEmpty {
                                    ForEach(section.footer) { $0 }
                                        .font(.system(size: 11)).lineSpacing(2)
                                        .foregroundStyle(TranslationSettingsPalette.ink2(dark: dark))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.top, 4)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: LiveLearnSettingsPage.contentMeasure, alignment: .leading)
                }
                .font(.system(size: 13))
                .toggleStyle(TranslationSettingsToggleStyle())
                .pickerStyle(.menu)
                .labeledContentStyle(TranslationSettingsLabeledContentStyle())
                .padding(.leading, gutter).padding(.trailing, 24).padding(.top, 26).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            configuration.content.padding(24)
        }
    }
}

/// The host's `QuietSwitchStyle` (round 12), mirrored: no ring, the state lives in the track.
/// On: the accent at 18 % under an accent knob. Off in the dark: the quiet fill under an `ink3`
/// knob. Off on paper: an ink 12 % track under a paper knob with a 0.75 pt `ink3` edge (1 pt
/// `ink2` under Increase Contrast) — a grey-green knob and a forest one are nearly the same
/// lightness, so "off" read as "on".
///
/// Increase Contrast, as the host: the on track at 45 % in the dark (30 % on paper); off in the
/// dark, the fill lifted to the host's (ink 16 %) inside a 1 pt `ink2` edge — the fixed 5.5 %
/// fill never rose, and the off track stayed at 1.08:1.
struct TranslationSettingsToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var showsLabel = true

    private var dark: Bool { colorScheme == .dark }
    private var accent: Color { dark ? TranslationSettingsPalette.silver : TranslationSettingsPalette.lightAccent }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 16) {
            if showsLabel {
                configuration.label.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            Button { configuration.isOn.toggle() } label: {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(track(on: configuration.isOn))
                        .overlay {
                            if increased && dark && !configuration.isOn {
                                Capsule().strokeBorder(TranslationSettingsPalette.ink2(dark: true), lineWidth: 1)
                            }
                        }
                    Circle().fill(knob(on: configuration.isOn))
                        .overlay {
                            if !configuration.isOn && !dark {
                                Circle().strokeBorder(increased ? TranslationSettingsPalette.ink2(dark: false) : TranslationSettingsPalette.ink3(dark: false),
                                                      lineWidth: increased ? 1 : 0.75)
                            }
                        }
                        .frame(width: 14, height: 14).padding(2)
                }
                .frame(width: 30, height: 18).padding(.horizontal, 7).padding(.vertical, 5)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, Capsule())
            }
            .buttonStyle(TranslationSettingsPressStyle())
            .padding(.horizontal, -7).padding(.vertical, -5)
        }
        .opacity(enabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isOn)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }

    private var increased: Bool { contrast == .increased }

    private func track(on: Bool) -> Color {
        if on { return accent.opacity(increased ? (dark ? 0.45 : 0.30) : 0.18) }
        guard dark else { return TranslationSettingsPalette.lightInk.opacity(0.12) }
        return increased ? RailInk.dark.ink.opacity(0.16) : TranslationSettingsPalette.fill(dark: true)
    }

    private func knob(on: Bool) -> Color {
        if on { return accent }
        return dark ? TranslationSettingsPalette.ink3(dark: true) : TranslationSettingsPalette.lightSurface
    }
}


struct TranslationSettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
        }
    }
}

struct TranslationSettingsPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && enabled ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .offset(y: configuration.isPressed && enabled && !reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : configuration.isPressed ? .easeOut(duration: 0.07)
                       : .spring(response: 0.26, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

struct TranslationSettingsActionStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        RailRowStyle(selected: selected).makeBody(configuration: configuration)
    }
}

struct TranslationSettingsInputSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .background(TranslationSettingsPalette.fill(dark: dark), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(TranslationSettingsPalette.rule(dark: dark), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct TranslationSettingsTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<_Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .modifier(TranslationSettingsInputSurface())
    }
}

struct TranslationSettingsField<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13))
            content().textFieldStyle(TranslationSettingsTextFieldStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranslationSettingsSheetStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .font(.system(size: 13))
            .tint(dark ? TranslationSettingsPalette.silver : TranslationSettingsPalette.lightAccent)
            .buttonStyle(TranslationSettingsActionStyle())
            .textFieldStyle(TranslationSettingsTextFieldStyle())
            .scrollContentBackground(.hidden)
            .background(dark ? TranslationSettingsPalette.ground : TranslationSettingsPalette.lightGround)
    }
}

/// The selected service row (round 12): the settings star point in the row's leading margin,
/// no fill — the selection grammar of every host list (a filled slab plus a 3 pt dot was the
/// helper's own). The `List` still owns the selection itself. The point's centre stands 5 pt
/// in, halo included inside the row's 10 pt margin: a `List` row may clip to its bounds.
///
/// The star is never the only sign: the chosen row's name is written in `ink`, the others rest
/// in `ink2`, as the host's paper-menu rows do. The second level is `ink3`, so the requirement
/// line under a name (`.secondary`) is exactly `ink3` rather than a secondary of `ink2`.
struct TranslationSettingsSelection: ViewModifier {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let ink = RailInk.of(dark: colorScheme == .dark)
        content
            .foregroundStyle(selected ? ink.ink : ink.ink2, ink.ink3)
            .padding(.horizontal, 10)
            .overlay(alignment: .leading) {
                if selected {
                    SettingsStarPoint(dark: colorScheme == .dark)
                        .offset(x: 1).allowsHitTesting(false)
                }
            }
    }
}

/// The List still owns selection, keyboard navigation and drag reorder.
struct TranslationSettingsListChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ListChromeView { ListChromeView() }
    func updateNSView(_ view: ListChromeView, context: Context) { view.scheduleUpdate() }

    final class ListChromeView: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let container = ancestor {
                    if let table = self?.findTable(in: container) {
                        table.selectionHighlightStyle = .none
                        table.backgroundColor = .clear
                        return
                    }
                    ancestor = container.superview
                }
            }
        }
        private func findTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let table = findTable(in: child) { return table }
            }
            return nil
        }
    }
}
