import SwiftUI

/// Settings on the black ground (§9.4, 0.7). A page is a title, then groups 32 pt apart; each
/// group is an 11 pt label and a run of rows with nothing around them; a row is a name in ink,
/// an optional explanation in `ink3` under it, and one control at the right rag (see `SettingRow`
/// for the one kind of control that sits under the name instead). Rows are
/// separated by rules that fade at their far end; nothing is boxed, filled or glassed, and
/// the controls are the same three tiers as the main window.

/// A run of rows. Put `SheetDivider()` between rows. No fill, no edge: the group label and
/// whitespace carry the structure.
struct SettingsSheet<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rule between two rows: solid from the text rag, fading over the last tenth, 1 px on
/// Retina — `FadingRule`'s default, which took its recipe from here. Never above a group's
/// first row or below its last.
struct SettingsRule: View {
    var body: some View { FadingRule() }
}

/// A rule between rows; the name every page already uses.
struct SheetDivider: View {
    var body: some View { SettingsRule() }
}

/// A group: label above, rows, optional note below.
///
/// Help lives here and only here (round 12): a group's `help` is the one bare "?" of its
/// section, at the rag of the label's line, and background a row used to carry beside its own
/// name is written into its group's help instead, so a reader always finds it in the same place.
///
/// A group's note hangs from its last row, under the row's own 12 pt padding (≈ 16 pt between
/// the glyphs) — with 8 pt more it stood 24 pt under the rows and 36 above the next label, and
/// floated between the two groups. A note that describes one row is that row's
/// (`SettingRow(note:)`), not the group's.
struct SettingsGroup<Content: View>: View {
    let title: String?
    var note: String? = nil
    var helpText: String? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme

    init(_ title: String? = nil, note: String? = nil, help: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.note = note
        self.helpText = help
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(1)) {
            if let title {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(title).font(LLFont.labelStrong).foregroundStyle(theme.ink2)
                    if let helpText {
                        Spacer(minLength: LLMetrics.space(4))
                        SettingsHelpButton(title: title, text: helpText)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingsSheet(content: content)
                if let note { SettingsNote(note) }
            }
        }
    }
}

/// Eleven-point explanation in `ink3`, wrapping: one step below the group label (`ink2`, 500).
/// Under a group's rows it stands 16 pt from the last row and 36 from the next group's label,
/// so it reads as that group's, never as the next one's.
struct SettingsNote: View {
    let text: String
    var color: Color? = nil
    @Environment(\.theme) private var theme

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(LLFont.label)
            .lineSpacing(2)
            .foregroundStyle(color ?? theme.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// How wide a control that sits under its name may be (§9.4). Two widths only, so a page of
/// them has one left edge and at most two right ones.
enum SettingsFieldWidth {
    /// An address, which can run long: the whole measure, so its right edge lands on the same
    /// rag as every trailing control. `.infinity` inside a row already is the measure.
    /// Only for `.frame(maxWidth:)` — passed to `.frame(width:)` it would be infinitely wide.
    static let measure: CGFloat = .infinity
    /// A name, an id or a key: 320 pt, room for a 40-character model name at 13 pt. Deliberately
    /// a content width, not derived from the measure — it stayed 320 when the measure went to 576.
    static let name: CGFloat = 320
}

/// One row: the name (and its explanation) at the left, the control at the right rag — the
/// reading order macOS uses, and the only axis a page's values may sit on (the "value axis"
/// was rejected, see doc/design/2026-09-14-settings-observatory-rail.md).
///
/// `below` is the single exception and it is decided by the kind of control, never by the row:
/// a control the user types into (`QuietField`), or one that writes lines back underneath
/// itself (`CredentialRow`, `TranslationTestRow`), cannot be one line at the rag, so it sits
/// under the name at the measure's left edge and the name reads as its group label. Its width
/// is one of the two in `SettingsFieldWidth`. Everything that is one line and fixed — a menu, a
/// switch, a segment, a slider, a colour well, a `SettingValue`, a single flush text button —
/// stays `trailing`. So "模型" is a menu at the rag under Whisper, a text button at the rag
/// under Apple, and a field under the name under a cloud engine: the axis follows the control.
///
/// Inside one group the rag rows come before the sunk ones, the sunk ones run unbroken, and the
/// axis changes once: a rag control that qualifies a form sits before the form, never inside it.
/// 兼容服务协议 is the only row in the repo that triggers this; it moved up to follow 引擎, and
/// its Tab / VoiceOver position moves with it, deliberately. The one control allowed after a
/// form is a switch that belongs to the whole engine rather than to one service — 也翻译未定稿
/// 的句子 — which closes its group with 32 pt of gap behind it instead of splitting the form.
///
/// This is the rule for the host's own pages. The bundled translation helper's service rows
/// (`ServiceCells`' `SecureInputCell` / `InputCell`) still keep their fields at the rag; that
/// page is not converted here.
///
/// `wide` is `trailing` for the one control that has no natural width — a slider with its value
/// (and a colour well beside it): at the rag like every other control, given up to 312 pt of
/// the row instead of being sized to fit.
///
/// A control at the rag (`trailing`, `wide`) is centred on the name's line and counts only that
/// line in layout (round 12): its own frame — a segment word's 34 pt, a switch's 18, a menu's
/// chevron — overhangs into the row's 12 pt padding instead of growing the row. Every one-line
/// row is then 40 pt, and a described row its name, note and padding, whatever it carries; rows
/// were 40, 42.5, 45 and 58 pt by control before, and a switch, aligned by its bottom edge to
/// the name's baseline, stood 3 pt high.
///
/// A row has no help mark of its own; its background goes into its group's help
/// (`SettingsGroup`).
struct SettingRow<Control: View>: View {
    enum Layout { case trailing, wide, below }

    let title: String
    var note: String? = nil
    var layout: Layout = .trailing
    /// Digits in the note keep their width (the 诊断 counters), so a live row never jitters.
    var monospacedNote = false
    @ViewBuilder var control: () -> Control
    @Environment(\.theme) private var theme

    /// The most a `wide` control takes of the row: a 220 pt slider, its 56 pt value slot and the
    /// 12 pt between them, plus a colour well where the row has one.
    static var wideControlWidth: CGFloat { 312 }
    /// The line of a 13 pt name (`LLFont.body`), which a control at the rag is centred on.
    static var nameLine: CGFloat { 16 }

    init(_ title: String, note: String? = nil, layout: Layout = .trailing, monospacedNote: Bool = false,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.note = note
        self.layout = layout
        self.monospacedNote = monospacedNote
        self.control = control
    }

    var body: some View {
        Group {
            switch layout {
            case .trailing:
                HStack(alignment: .top, spacing: LLMetrics.space(4)) {
                    label
                    Spacer(minLength: LLMetrics.space(2))
                    control()
                        .fixedSize()
                        .frame(height: Self.nameLine)
                }
            case .wide:
                HStack(alignment: .top, spacing: LLMetrics.space(4)) {
                    label
                    Spacer(minLength: LLMetrics.space(2))
                    control()
                        .frame(maxWidth: Self.wideControlWidth, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(height: Self.nameLine)
                }
            case .below:
                VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
                    label
                    control()
                }
            }
        }
        .padding(.vertical, LLMetrics.space(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(LLFont.body).foregroundStyle(theme.ink)
            if let note {
                Text(note).font(monospacedNote ? LLFont.label.monospacedDigit() : LLFont.label)
                    .lineSpacing(2).foregroundStyle(theme.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A section's help: a bare "?" 11/400 in `ink3` that lifts to `ink2` under the pointer — no
/// circle, no icon (the circled glyph was the only icon left in the content column). It stands
/// at the rag of the group label's line, on the label's baseline, the glyph ending its 14 pt box
/// so its ink meets the rag with the controls below. Right after a CJK label, 6 pt on, it was
/// spaced like the label's next character and read as a question mark ("（固定）?"); regular
/// and not the label's own 500 face, so the two never read as one string. Its 28 × 28 target is
/// taken back out of the layout, so a group with help is exactly as tall as one without (the
/// label line used to grow from 14 to 28 pt and push that group's rows down). The explanation
/// opens on the ground, arrow included.
struct SettingsHelpButton: View {
    let title: String
    let text: String
    @Environment(\.theme) private var theme
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Text("?").font(LLFont.label).frame(width: 14, height: 14, alignment: .trailing)
        }
        .buttonStyle(SettingsHelpMarkStyle(open: presented))
        .accessibilityLabel("\(title)说明")
        .help("查看说明")
        .popover(isPresented: $presented) {
            Text(text).font(LLFont.body).foregroundStyle(theme.ink2)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled).padding(16).frame(width: 320)
                .presentationBackground(theme.ground)
        }
    }
}

/// The help mark's ink and target: `ink3` at rest, `ink2` under the pointer or while its
/// explanation is open; pressed at 55 % with the settings press. The target reaches 7 pt past
/// the glyph box on every side, outside the layout.
private struct SettingsHelpMarkStyle: ButtonStyle {
    let open: Bool

    func makeBody(configuration: Configuration) -> some View {
        MarkBody(configuration: configuration, open: open)
    }

    private struct MarkBody: View {
        let configuration: Configuration
        let open: Bool
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(enabled && (hovering || open) ? theme.ink2 : theme.ink3)
                .opacity(configuration.isPressed && enabled ? 0.55 : 1)
                .contentShape(Rectangle().inset(by: -7))
                .contentShape(.focusEffect, Circle().inset(by: -5))
                .modifier(ControlPressFeedback(pressed: configuration.isPressed, enabled: enabled))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
        }
    }
}

extension SettingRow where Control == EmptyView {
    /// A row that only states something. Laid out `below`, where the missing control takes no
    /// room: at the rag its empty line slot would still cost the note a gap's width.
    init(_ title: String, note: String? = nil) {
        self.init(title, note: note, layout: .below) { EmptyView() }
    }
}

/// A fact in `ink2` at the right of a row; digits are monospaced so readings that change
/// ("已安装 · 626 MB", a percent) never move their neighbours.
struct SettingValue: View {
    let text: String
    var color: Color? = nil
    @Environment(\.theme) private var theme

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(LLFont.body.monospacedDigit())
            .foregroundStyle(color ?? theme.ink2)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }
}

/// Quiet switch: a 30 × 18 capsule with no ring — the state lives in the track itself (round
/// 12). On, the track takes the `accent` at 18 % and the knob is the `accent` (silver-white in
/// the dark, forest on paper), the same material as the helper's switches. Off in the dark, the
/// track is the quiet `fill` and the knob `ink3`.
///
/// Increase Contrast gives the track an edge back in the dark, where the ring's removal left it
/// under 1.5:1 in both states: on, the accent at 45 % (3.8:1 on the ground, the old ring's
/// value, the knob still 4.4:1 against it; 30 % on paper); off, a 1 pt `ink2` edge round the
/// lifted `fill` — the dark twin of the paper knob's 1 pt `ink2` edge below.
///
/// Off on paper is its own recipe, because a grey-green knob and a forest one are nearly the
/// same lightness and "off" read as "on": the knob is paper (`surface`) with a 0.75 pt `ink3`
/// edge (≈ 4.7:1 against the ground; 1 pt `ink2` under Increase Contrast) on an `ink` 12 %
/// track. The forest `fill` track and a half-strength edge measured 1.1:1 and 2:1, so the
/// whole control faded to a ghost circle (WCAG 1.4.11 asks 3:1 of a state indicator).
///
/// The target reaches 3pt above and below (24pt, §11) without the capsule moving in its row; a
/// press dims it like a filled control.
struct QuietSwitchStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    /// The title the caller gives the Toggle is never drawn (the row already names it) but it is
    /// the switch's accessibility name, so every switch is called something.
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        let paperOff = !on && !theme.isDark
        let increased = contrast == .increased
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? theme.accent.opacity(increased ? (theme.isDark ? 0.45 : 0.30) : 0.18)
                             : (paperOff ? theme.ink.opacity(0.12) : theme.fill))
                    .overlay {
                        if increased && theme.isDark && !on { Capsule().strokeBorder(theme.ink2, lineWidth: 1) }
                    }
                Circle()
                    .fill(on ? theme.accent : (paperOff ? theme.surface : theme.ink3))
                    .overlay {
                        if paperOff {
                            Circle().strokeBorder(increased ? theme.ink2 : theme.ink3, lineWidth: increased ? 1 : 0.75)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            // The knob travels on the enter curve (fast start, soft stop), 180ms.
            .animation(LLMotion.toggle(reduceMotion), value: configuration.isOn)
            .opacity(enabled ? 1 : 0.5)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .contentShape(.focusEffect, Capsule())
        }
        .buttonStyle(PressDimStyle(dim: 0.86))
        // Take the hit area back out of the layout in both directions, or the capsule stops
        // 7 pt short of the right rag where every other control lands. Target stays 44 × 28.
        .padding(.vertical, -5).padding(.horizontal, -7)
        .accessibilityLabel { _ in configuration.label }
        .accessibilityValue(configuration.isOn ? "开" : "关")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row of text choices with no fill: the chosen word is written in `ink` and carries a
/// stamped point of light under it; the others rest in `ink2` and lift under the pointer. The
/// layout and weight stay fixed; hover light and a brief press acknowledge interaction.
/// The point is an overlay at a fixed offset. `label` names the group for
/// VoiceOver ("预设", "译文字重").
struct TextSegment<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var label: String? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, name in
                SegmentWord(name: name, selected: selection == value) { selection = value }
            }
        }
        // Each word's 10 pt hit padding is counted in layout, so without this the segment sits
        // 10 pt in from the left rag and ends 10 pt short of the right one. Hit areas unchanged.
        .padding(.horizontal, -10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label ?? "")
    }

    /// The selected point stays distinct from the transient hover and press feedback.
    private struct SegmentWord: View {
        let name: String
        let selected: Bool
        let action: () -> Void
        @Environment(\.theme) private var theme

        var body: some View {
            Button(action: action) {
                Text(name)
                    .font(LLFont.body)
                    // On the word's text box, not on the padded frame: see `SettingsStarPoint`.
                    .overlay(alignment: .bottom) {
                        if selected { SettingsStarPoint(dark: theme.isDark, stamped: true) }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailRowStyle(selected: selected, dark: theme.isDark))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Slider in the accent with its value beside it, monospaced so the row never jitters. `label`
/// is the slider's accessibility name; VoiceOver reads the formatted value ("26 pt"), not the
/// raw fraction.
struct QuietSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    @Environment(\.theme) private var theme

    /// Snapped in the binding rather than with `step:` so the slider draws no tick marks.
    private var snapped: Binding<Double> {
        Binding(
            get: { value },
            set: { value = min(max((($0 / step).rounded()) * step, range.lowerBound), range.upperBound) }
        )
    }

    var body: some View {
        HStack(spacing: LLMetrics.space(3)) {
            Slider(value: snapped, in: range) { Text(label) }
                .labelsHidden()
                .tint(theme.accent)
                .controlSize(.small)
                .frame(maxWidth: 220)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(LLFont.body.monospacedDigit())
                .foregroundStyle(theme.ink2)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

/// A text field: `surface` fill, hairline edge, 6pt radius. `focus` lets the page put the
/// cursor in it (the 词汇 entry line); `onSubmit` is the return key.
///
/// Focus is drawn in the paper's own ink instead of the system's blue ring: the hairline
/// becomes a 1px `ink2` edge (6:1 on the ground) while the field is first responder, and the
/// pointer lifts it halfway there. Colour only; the field never changes size. Under Increase
/// Contrast the system ring is left on as well.
struct QuietField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var focus: FocusState<Bool>.Binding? = nil
    var onSubmit: (() -> Void)? = nil
    /// The field's paper. Settings rows lie on the ground itself, so the default is `surface`
    /// (a strip of paper) and the field never reads as an outline alone; a caller that puts a
    /// field inside a `surface` sheet passes `ground`.
    var fill: Color? = nil
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if staticRender {
                Text(text.isEmpty ? placeholder : (secure ? String(repeating: "•", count: 8) : text))
                    .foregroundStyle(text.isEmpty ? theme.ink3 : theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if secure {
                focused(SecureField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(theme.ink3)))
            } else {
                focused(TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(theme.ink3)))
            }
        }
        .onSubmit { onSubmit?() }
        .textFieldStyle(.plain)
        .font(LLFont.body)
        .foregroundStyle(theme.ink)
        .padding(.horizontal, 10)
        .frame(height: LLMetrics.controlHeight)
        .background(fill ?? theme.surface, in: RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: LLMetrics.Radius.control, style: .continuous).strokeBorder(edge, lineWidth: 1))
        .onHover { hovering = $0 }
        .animation(LLMotion.hover(reduceMotion), value: hasFocus)
        .animation(LLMotion.hover(reduceMotion), value: hovering)
    }

    private var hasFocus: Bool { focus?.wrappedValue ?? isFocused }
    private var edge: Color {
        if hasFocus { return theme.ink2 }
        // Under Increase Contrast the resting hairline is lifted to about ink3 at half, so the
        // pointer's edge goes further to still read as a lift.
        if hovering { return theme.ink3.opacity(theme.raisesContrast ? 0.8 : 0.5) }
        // At rest on paper the hairline is the edge (the well is barely darker than the sheet);
        // in the dark the step from sheet to black is the edge, and a brighter line outlines it —
        // except under Increase Contrast, where that 1.1:1 step is no edge at all and the lifted
        // hairline (≈ 2.5:1) draws it, as it did before the dark wells lost their line.
        return theme.isDark && fill != nil && !theme.raisesContrast ? .clear : theme.hairline
    }

    @ViewBuilder
    private func focused<Field: View>(_ field: Field) -> some View {
        field.focused(focus ?? $isFocused).focusEffectDisabled(contrast != .increased)
    }
}

/// A colour on paper: a 28 × 18 swatch of the bound colour with a hairline edge, drawn here in
/// both the live and the offscreen path so the screen and the render are the same pixels. It was
/// the system `ColorPicker` on screen, which drew a 46 × 24 white capsule inside a grey system
/// border — the one large bright fill in a surface whose whole claim is that light comes from
/// points, not from areas. Choosing the colour is still the system's job: a click opens
/// `NSColorPanel`, which writes every change straight back into the binding.
struct QuietColorWell: View {
    let label: String
    @Binding var color: Color
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.isEnabled) private var enabled
    @State private var panel = ColorPanelBridge()

    var body: some View {
        if staticRender {
            swatch.accessibilityLabel(label)
        } else {
            Button {
                panel.present(color, title: label) { color = $0 }
            } label: {
                swatch.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .opacity(enabled ? 1 : 0.5)
            .accessibilityLabel(label)
            .accessibilityValue(HexColor.hex(from: color))
            .help(label)
            // The panel outlives this view — collapsing 对比与描边, turning 显示原文 off or leaving
            // the page all take the swatch out of the tree while the panel is still up — and
            // `setTarget:` is the classic unretained AppKit target, so the bridge has to hand it
            // back here too, not only when the panel closes.
            .onDisappear { panel.resign() }
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.hairline, lineWidth: 1))
            .frame(width: 28, height: 18)
    }
}

/// Points the one shared `NSColorPanel` at the swatch that was clicked: it seeds the panel with
/// that swatch's colour, takes the panel's target while it is open so every change lands in that
/// binding, and lets go — on the panel's close **and** on the swatch's `onDisappear`, whichever
/// comes first — so a later swatch never writes into an older one and the panel is never left
/// pointing at a released bridge. `-[NSColorPanel setTarget:]` is the classic AppKit setter: no
/// property, no documented ownership, so it must be assumed unretained.
@MainActor
private final class ColorPanelBridge: NSObject {
    /// The bridge the shared panel is currently pointed at. A bridge that is torn down while some
    /// *other* swatch owns the panel must not clear that swatch's target, and `NSColorPanel` has
    /// no public `target` getter to ask.
    private static weak var owner: ColorPanelBridge?
    private var apply: ((Color) -> Void)?

    func present(_ color: Color, title: String, apply: @escaping (Color) -> Void) {
        self.apply = apply
        Self.owner = self
        let panel = NSColorPanel.shared
        // Every swatch in Settings is an opaque ink; opacity is its own row where a page has one.
        panel.showsAlpha = false
        panel.color = NSColor(color)
        panel.title = title
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Hands the panel back. Idempotent, and safe to call on a bridge that never presented.
    func resign() {
        let panel = NSColorPanel.shared
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        apply = nil
        guard Self.owner === self else { return }
        Self.owner = nil
        panel.setTarget(nil)
        panel.setAction(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        apply?(Color(nsColor: sender.color))
    }

    @objc private func panelWillClose(_ note: Notification) {
        resign()
    }
}

/// Page title at the top of a settings page: pure type, the size of the first line of an
/// empty window (`LLFont.display`), with the page's one-line description 8 pt under it. No
/// symbol, no badge, no rule; the sidebar's first group label shares its baseline (the spacing
/// that holds them on one line is `LiveLearnSettingsPage.sidebarHeadingSpacing`).
struct SettingsPageTitle: View {
    let text: String
    var note: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: LLMetrics.space(2)) {
            Text(text).font(LLFont.display).foregroundStyle(theme.ink)
            if let note {
                Text(note).font(LLFont.body).lineSpacing(LLLeading.body).foregroundStyle(theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
