import SwiftUI
import CaptionDomain

enum OverlayControl { case language, engine, type, opacity }

/// Controls keep their own opaque surface, regardless of the caption background setting.
struct OverlayToolbar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Binding var openControl: OverlayControl?
    var compact = false
    var onFocusChange: (Bool) -> Void = { _ in }
    @FocusState private var focusedControl: String?
    @AccessibilityFocusState private var accessibleControl: String?

    private var direction: String {
        guard let lane = model.lanes.first else {
            return StatusCopy.direction(model.settings.listenSourceLanguage, model.settings.listenTargetLanguage)
        }
        return StatusCopy.direction(lane.configuration.sourceLanguage ?? LanguageCatalog.auto, lane.configuration.targetLanguage)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { openControl = .language } label: {
                Label(model.lanes.count > 1 || compact ? "语言" : direction, systemImage: "globe")
                    .lineLimit(1)
            }
            .help("识别语言与翻译输出语言 · \(direction)")
            .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "language"))
            .popover(isPresented: presented(.language), arrowEdge: .top) {
                OverlayLanguageEditor().environment(model).overlayControlSurface()
            }
            Button { openControl = .engine } label: {
                Label("引擎", systemImage: "cpu")
            }
            .accessibilityLabel("切换字幕引擎")
            .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "engine"))
            .help("识别与翻译 · \(model.blueprint.summary)")
            .popover(isPresented: presented(.engine), arrowEdge: .top) {
                OverlayEngineEditor().environment(model).overlayControlSurface()
            }
            Button { model.settings.showSourceInOverlay.toggle() } label: {
                Label("原文", systemImage: model.settings.showSourceInOverlay ? "captions.bubble.fill" : "captions.bubble")
            }
            .accessibilityValue(model.settings.showSourceInOverlay ? "显示" : "隐藏")
            .disabled(model.settings.captionPresentation == .singleLine)
            .accessibilityAddTraits(.isToggle)
            .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "source"))
            .help(model.settings.captionPresentation == .singleLine ? "单行字幕只显示译文；分层显示可查看原文" : model.settings.showSourceInOverlay ? "隐藏原文，只显示译文" : "同时显示原文与译文")
            Button { openControl = .type } label: {
                Image(systemName: "textformat.size").frame(width: 24)
            }
            .accessibilityLabel("调整字幕样式")
            .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "type"))
            .help("字体、颜色、对比与字幕布局")
            .popover(isPresented: presented(.type), arrowEdge: .top) {
                OverlayTypeEditor().environment(model).overlayControlSurface()
            }
            Button { openControl = .opacity } label: {
                Image(systemName: "circle.lefthalf.filled").frame(width: 20)
            }
            .accessibilityLabel("调整背景不透明度")
            .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "opacity"))
            .help("背景不透明度 · 0% 完全透明")
            .popover(isPresented: presented(.opacity), arrowEdge: .top) {
                OverlayOpacityEditor().environment(model).overlayControlSurface()
            }
            Spacer(minLength: 0)
            Button { model.toggleLock() } label: { Image(systemName: model.overlayLocked ? "lock.fill" : "lock.open").frame(width: 18) }
                .accessibilityLabel(model.overlayLocked ? "解除字幕锁定" : "锁定字幕并穿透点击")
                .accessibilityValue(model.overlayLocked ? "已锁定" : "未锁定")
                .accessibilityAddTraits(.isToggle)
                .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "lock"))
                .help(model.overlayLocked ? "解除锁定，可拖动字幕" : "锁定后正文点击穿透；移到顶部可解锁")
            Button { model.hideOverlay() } label: { Image(systemName: "xmark").frame(width: 18) }
                .accessibilityLabel("隐藏字幕")
                .modifier(OverlayControlFocus(keyboard: $focusedControl, accessibility: $accessibleControl, id: "close"))
                .help(model.overlayCloseHelp)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(theme.ink)
        .buttonStyle(OverlayButtonStyle())
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .onChange(of: focusedControl) { _, _ in onFocusChange(focusedControl != nil || accessibleControl != nil) }
        .onChange(of: accessibleControl) { _, _ in onFocusChange(focusedControl != nil || accessibleControl != nil) }
        .onDisappear { onFocusChange(false) }
    }

    private func presented(_ control: OverlayControl) -> Binding<Bool> {
        Binding(get: { openControl == control }, set: { if !$0 && openControl == control { openControl = nil } })
    }
}

private struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(pressed: configuration.isPressed) { configuration.label }
    }

    private struct HoverLabel<Content: View>: View {
        let pressed: Bool
        @ViewBuilder var content: () -> Content
        @State private var hovering = false
        @Environment(\.theme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            content()
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(enabled && pressed ? theme.fillPressed : (enabled && hovering ? theme.fillHover : .clear), in: RoundedRectangle(cornerRadius: 6))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 6))
                .modifier(ControlPressFeedback(pressed: pressed, enabled: enabled))
                .onHover { hovering = $0 }
                .animation(LLMotion.hover(reduceMotion), value: hovering)
        }
    }
}

private extension View {
    func overlayControlSurface() -> some View {
        modifier(OverlayControlSurface())
    }
}

private struct OverlayControlSurface: ViewModifier {
    @Environment(\.theme) private var theme
    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(width: 340)
            .foregroundStyle(theme.ink)
            .tint(theme.accent)
            .background(theme.surface)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

private struct OverlayTypeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 18) {
            Text("字幕样式").font(.headline)
            PaperChoiceRow(label: "呈现方式", selection: $settings.captionPresentation,
                           options: CaptionPresentation.allCases, title: { $0.label }, help: settings.captionPresentation.note)
            PaperChoiceRow(label: "字体", selection: $settings.overlayFontFamily,
                options: [""] + OverlayTypography.families +
                    (!settings.overlayFontFamily.isEmpty && !OverlayTypography.families.contains(settings.overlayFontFamily) ? [settings.overlayFontFamily] : []),
                title: { $0.isEmpty ? "系统字体" : OverlayTypography.label($0) }, help: "字幕字体")
            ColorPicker("译文颜色", selection: Binding(
                get: { HexColor.color(settings.overlayTextHex, fallback: LLOverlay.text) },
                set: { settings.overlayTextHex = HexColor.hex(from: $0) }), supportsOpacity: false)
            PaperChoiceRow(label: "对比模式", selection: $settings.overlayContrastMode, options: OverlayContrastMode.allCases, title: { $0.label })
            CaptionAutoContrastPermission()
            OverlaySlider(title: "译文字号", value: $settings.captionTargetSize, range: 18...40, step: 1, suffix: " pt")
            OverlaySlider(title: "原文字号", value: $settings.captionSourceSize, range: 12...28, step: 1, suffix: " pt")
                .disabled(settings.captionPresentation == .singleLine)
            OverlaySlider(title: "字幕宽度", value: $settings.captionDisplayWidth, range: 480...1400, step: 10, suffix: " pt")
            Divider()
            Toggle("显示上一句译文", isOn: $settings.showPreviousLine)
                .disabled(settings.captionPresentation == .singleLine)
            Toggle("显示呼吸线", isOn: $settings.showBreathLine)
                .disabled(settings.captionPresentation == .singleLine)
            Button("更多样式与画面预览…") {
                model.settings.requestedSettingsTab = .appearance
                dismiss()
                UnifiedSettingsPresentation.shared.open()
            }
            .buttonStyle(TextButtonStyle())
        }
        .font(.system(size: 13))
    }
}

private struct OverlayOpacityEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var systemForcesOpaque: Bool { reduceTransparency || contrast == .increased }

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            Text("背景不透明度").font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(systemForcesOpaque || settings.overlayOpaque ? "100%" : "\(Int((settings.overlayOpacity * 100).rounded()))%")
                    .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                Spacer()
                Text(settings.overlayOpacity == 0 && !systemForcesOpaque && !settings.overlayOpaque ? "只留字幕" : "字幕文字始终清晰")
                    .font(.system(size: 12)).foregroundStyle(theme.ink2)
            }
            Slider(value: $settings.overlayOpacity, in: 0...1, step: 0.01)
                .accessibilityLabel("背景不透明度")
                .disabled(systemForcesOpaque || settings.overlayOpaque)
            HStack {
                Button("完全透明") { settings.overlayOpaque = false; settings.overlayOpacity = 0 }
                Spacer()
                Button("柔和底色") { settings.overlayOpaque = false; settings.overlayOpacity = 0.45 }
                Spacer()
                Button("不透明") { settings.overlayOpacity = 1 }
            }
            .buttonStyle(TextButtonStyle())
            .font(.system(size: 12))
            .disabled(systemForcesOpaque)
            Divider()
            Toggle("始终不透明", isOn: $settings.overlayOpaque)
            Text(systemForcesOpaque ? "系统的减少透明度或增强对比度已开启，当前使用不透明背景。" : "只调整字幕背景，不会淡化文字。拖动字幕文字可移动位置。")
                .font(.system(size: 12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
    }
}

private struct OverlaySlider: View {
    @Environment(\.theme) private var theme
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.rounded()))\(suffix)").monospacedDigit().foregroundStyle(theme.ink2)
            }
            Slider(value: $value, in: range, step: step).accessibilityLabel(title)
        }
    }
}

private struct OverlayLanguageEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var selection: OverlayLanguages?
    @State private var applying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("字幕语言").font(.headline)
            if selection != nil {
                if model.useApplication || model.useSystem {
                    languagePair("电脑里的声音", source: languageBinding(\.listenSource), target: languageBinding(\.listenTarget))
                }
                if model.useMicrophone {
                    languagePair("我说的话", source: languageBinding(\.micSource), target: languageBinding(\.micTarget))
                }
            }
            Text(model.isActive ? "切换语言会保留本次记录，并开始新会话。" : "设置将用于下一次会话。")
                .font(.system(size: 12)).foregroundStyle(theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(theme.ochre).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(applying ? "正在切换…" : model.isActive ? "应用并重新开始" : "应用") {
                    guard let selection else { return }
                    applying = true
                    error = nil
                    Task { @MainActor in
                        error = await model.applyOverlayLanguages(selection)
                        applying = false
                        if error == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil || selection == OverlayLanguages(settings: model.settings))
            }
        }
        .disabled(applying)
        .font(.system(size: 13))
        .onAppear { selection = OverlayLanguages(settings: model.settings) }
    }

    private func languageBinding(_ key: WritableKeyPath<OverlayLanguages, String>) -> Binding<String> {
        Binding(get: { selection?[keyPath: key] ?? "en" }, set: { selection?[keyPath: key] = $0; error = nil })
    }

    private func languagePair(_ title: String, source: Binding<String>, target: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(theme.ink2)
            PaperChoiceRow(label: "识别语言", selection: source, options: [LanguageCatalog.auto] + LanguageCatalog.all.map(\.code), title: LanguageCatalog.name)
            PaperChoiceRow(label: "输出语言", selection: target, options: LanguageCatalog.all.map(\.code), title: LanguageCatalog.name)
        }
    }
}

/// Native focus bridges are only mounted in live windows; ImageRenderer draws the same
/// controls directly so deterministic review images retain every label and button.
private struct OverlayControlFocus: ViewModifier {
    let keyboard: FocusState<String?>.Binding
    let accessibility: AccessibilityFocusState<String?>.Binding
    let id: String
    @Environment(\.staticRender) private var staticRender

    @ViewBuilder func body(content: Content) -> some View {
        if staticRender { content }
        else { content.focused(keyboard, equals: id).accessibilityFocused(accessibility, equals: id) }
    }
}
