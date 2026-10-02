// Settings-only selection controls. Original options and bindings remain owned by Easydict. GPL-3.0.
import AppKit
import SwiftUI

protocol TranslationMenuTitled {
    var translationMenuTitle: String { get }
}


extension AppearanceType: TranslationMenuTitled {
    var translationMenuTitle: String { title }
}

extension LanguageState.LanguageType: TranslationMenuTitled {
    var translationMenuTitle: String { name }
}

extension MaxWindowHeightPercentageOption: TranslationMenuTitled {
    var translationMenuTitle: String { title }
}

func translationMenuTitle(_ value: Any) -> String? {
    if let language = value as? Language { return language.localizedName }
    if let titled = value as? TranslationMenuTitled { return titled.translationMenuTitle }
    if let resource = value as? any CustomLocalizedStringResourceConvertible {
        return String(localized: resource.localizedStringResource)
    }
    if let text = value as? String { return text.isEmpty ? "—" : text }
    if let titled = value as? any EnumLocalizedStringConvertible, let key = titled.title.stringKey {
        return NSLocalizedString(key, comment: "")
    }
    return nil
}


private struct TranslationInterfaceScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var translationInterfaceScale: CGFloat {
        get { self[TranslationInterfaceScaleKey.self] }
        set { self[TranslationInterfaceScaleKey.self] = newValue }
    }
}

struct TranslationSettingsPicker<Value: Hashable, OptionLabel: View, Label: View>: View {
    let selection: Binding<Value>
    let options: [Value]
    let optionLabel: (Value) -> OptionLabel
    let label: Label
    var titleKey: LocalizedStringKey?

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Value], @ViewBuilder content: @escaping (Value) -> OptionLabel) where Label == Text {
        self.selection = selection; self.options = options; self.optionLabel = content
        self.label = Text(title); self.titleKey = title
    }
    init(selection: Binding<Value>, options: [Value], @ViewBuilder content: @escaping (Value) -> OptionLabel, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.options = options; self.optionLabel = content; self.label = label()
    }
    init(selection: Binding<Value>, label: Label, options: [Value], @ViewBuilder content: @escaping (Value) -> OptionLabel) {
        self.selection = selection; self.options = options; self.optionLabel = content; self.label = label
    }

    var body: some View {
        HStack(spacing: 16) {
            label.fixedSize(horizontal: false, vertical: true).accessibilityHidden(titleKey != nil)
            Spacer(minLength: 12)
            TranslationChoiceMenu(selection: selection, options: options, optionLabel: optionLabel)
                .accessibilityLabel(titleKey.map { Text($0) } ?? Text(translationMenuTitle(selection.wrappedValue) ?? "选择选项"))
        }
    }
}

struct TranslationModelGroupMenu: View {
    @Binding var selection: String
    let groups: [String]
    var body: some View {
        TranslationChoiceMenu(selection: $selection, options: [""] + groups, slot: 140,
            title: { $0.isEmpty ? "全部" : $0 }) { Text(verbatim: $0.isEmpty ? "全部" : $0) }
            .accessibilityLabel("模型分组")
    }
}

/// The embedded pages' closed menu, in the host `PaperMenu`'s grammar (round 12): the value in
/// 13 pt and a 7.5 pt chevron 3 pt after it that lifts from `ink3` to `ink2` under the pointer
/// or while open; in the list, the chosen row carries the settings star point in a leading
/// slot, as a paper-menu row does, instead of a trailing checkmark.
///
/// And the rows' ink, as a paper-menu row's: resting rows in `ink2`, the chosen row and the one
/// under the pointer or keyboard in `ink` — the star is never the only sign of the choice. The
/// highlight tint is a step stronger on the chosen row (the host's `fillHover`), which is
/// already in `ink` and would otherwise answer ↑ ↓ with the tint alone. The star grows with
/// 界面大小 like the rows around it (`SettingsStarPoint(scale:)`), as the checkmark it replaced did.
struct TranslationChoiceMenu<Value: Hashable, OptionLabel: View>: View {
    @Binding var selection: Value
    let options: [Value]
    var slot: CGFloat = 220
    var title: (Value) -> String = { translationMenuTitle($0) ?? String(describing: $0) }
    @ViewBuilder var optionLabel: (Value) -> OptionLabel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.translationInterfaceScale) private var scale
    @State private var open = false
    @State private var hovering = false
    @State private var query = ""
    @State private var highlighted: Value?
    @State private var keyboardPointer: NSPoint?

    private var dark: Bool { colorScheme == .dark }
    private var surface: Color { dark ? Color(red: 16.0 / 255, green: 17.0 / 255, blue: 20.0 / 255) : TranslationSettingsPalette.lightSurface }
    private var ink: RailInk { RailInk.of(dark: dark) }
    private var searchable: Bool { options.count > 12 || !query.isEmpty }
    private var filtered: [Value] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.filter { value in
            var words = [title(value)]
            if let language = value as? Language { words += [language.englishName, language.nativeName, language.code] }
            return term.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
    private var menuWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = options.map { (title($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 140
        return min(360, max(searchable ? 250 : 180, widest + 72)) * scale
    }
    private var menuHeight: CGFloat {
        let rows = filtered.isEmpty ? 44 : CGFloat(filtered.count) * 28
        return min((rows + 12 + (searchable ? 42 : 0)) * scale, 380 * scale,
                   (NSApp.keyWindow?.screen?.visibleFrame.height ?? 900) * 0.65)
    }

    var body: some View {
        Button {
            query = ""; keyboardPointer = nil; highlighted = options.contains(selection) ? selection : options.first; open.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: title(selection)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(hovering || open ? ink.ink2 : ink.ink3)
                    .rotationEffect(.degrees(open ? 180 : 0)).accessibilityHidden(true)
            }
            .font(.system(size: 13)).padding(.vertical, 5).frame(maxWidth: slot, alignment: .trailing)
            .contentShape(Rectangle())
        }
        // The value is written in `ink` like the host's menu values; hover adds the light.
        .buttonStyle(TranslationSettingsActionStyle(selected: true))
        .onHover { hovering = $0 }
        .accessibilityValue(title(selection))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6 * scale) {
                if searchable {
                    TranslationMenuSearch(text: $query, title: Value.self == Language.self ? "搜索语言" : "搜索选项", fontSize: 13 * scale,
                        move: move, submit: { choose(highlighted ?? filtered.first) }, cancel: { open = false })
                        .frame(height: 18 * scale).padding(8 * scale)
                        .background(TranslationSettingsPalette.fill(dark: dark), in: RoundedRectangle(cornerRadius: 6))
                }
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered, id: \.self) { value in
                                let chosen = value == selection
                                Button { choose(value) } label: {
                                    HStack(spacing: 8 * scale) {
                                        ZStack { if chosen { SettingsStarPoint(dark: dark, scale: scale) } }
                                            .frame(width: 8 * scale, height: 8 * scale).accessibilityHidden(true)
                                        optionLabel(value).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 4)
                                    }
                                    .foregroundStyle(chosen || highlighted == value ? ink.ink : ink.ink2)
                                    .font(.system(size: 13 * scale)).padding(.horizontal, 10 * scale).frame(height: 28 * scale)
                                    .background(highlighted == value ? ink.ink.opacity(highlightAlpha(chosen: chosen)) : .clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(value).help(title(value))
                                .accessibilityLabel(title(value))
                                .onContinuousHover { phase in
                                    if case .active = phase, keyboardPointer != NSEvent.mouseLocation {
                                        keyboardPointer = nil; highlighted = value
                                    }
                                }
                                .accessibilityAddTraits(value == selection ? .isSelected : [])
                            }
                            if filtered.isEmpty { Text("没有可用选项").font(.system(size: 13 * scale)).padding(12 * scale) }
                        }
                    }
                    .onAppear { if let highlighted { reader.scrollTo(highlighted, anchor: .center) } }
                    .onChange(of: highlighted) { value in if let value { reader.scrollTo(value) } }
                }
            }
            .padding(6 * scale).frame(width: menuWidth, height: menuHeight)
            .foregroundStyle(ink.ink).background(surface)
            .background {
                if !searchable {
                    TranslationMenuKeys(move: move, submit: { choose(highlighted) }, cancel: { open = false })
                }
            }
            .onChange(of: query) { _ in highlighted = filtered.contains(selection) ? selection : filtered.first }
            .onChange(of: options) { values in
                if let highlighted, !values.contains(highlighted) { self.highlighted = filtered.first }
            }
        }
    }

    private func choose(_ value: Value?) {
        guard let value, options.contains(value) else { return }
        selection = value; open = false
    }
    private func highlightAlpha(chosen: Bool) -> Double {
        contrast == .increased ? (chosen ? 0.22 : 0.18) : (chosen ? 0.14 : 0.10)
    }
    private func move(_ delta: Int) {
        let values = filtered
        guard !values.isEmpty else { return }
        keyboardPointer = NSEvent.mouseLocation
        let index = highlighted.flatMap { values.firstIndex(of: $0) } ?? (delta > 0 ? -1 : values.count)
        highlighted = values[min(values.count - 1, max(0, index + delta))]
    }
}

private struct TranslationMenuKeys: NSViewRepresentable {
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.actions = self }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.detach() }
    final class KeyView: NSView {
        var actions: TranslationMenuKeys?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isVisible == true else { return event }
                return self.handle(event) ? nil : event
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeKey()
                window.makeFirstResponder(self)
            }
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        override func keyDown(with event: NSEvent) {
            if !handle(event) { super.keyDown(with: event) }
        }
        private func handle(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch event.keyCode {
            case 125: actions?.move(1)
            case 126: actions?.move(-1)
            case 36, 76, 49: actions?.submit()
            case 53, 48: actions?.cancel()
            default: return false
            }
            return true
        }
    }
}

private struct TranslationMenuSearch: NSViewRepresentable {
    @Binding var text: String
    let title: String
    let fontSize: CGFloat
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = SearchField()
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = title
        field.setAccessibilityLabel(title)
        field.font = NSFont.systemFont(ofSize: fontSize)
        if field.stringValue != text { field.stringValue = text }
    }
    final class SearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: TranslationMenuSearch
        init(parent: TranslationMenuSearch) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch NSStringFromSelector(command) {
            case "moveDown:": parent.move(1)
            case "moveUp:": parent.move(-1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.cancel()
            default: return false
            }
            return true
        }
    }
}
