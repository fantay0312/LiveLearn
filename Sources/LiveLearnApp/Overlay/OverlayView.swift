import SwiftUI
import AudioDomain
import CaptionDomain
import SessionDomain

private struct OverlayHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The toolbar has its own reserved transparent strip: revealing it never moves a caption.
struct OverlayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(OverlayLayout.self) private var layout: OverlayLayout?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var revealed = false
    @State private var openControl: OverlayControl?
    @State private var hoverInside = false
    @State private var toolbarFocused = false

    var forcedWidth: CGFloat? = nil
    var previewControls = false

    private var style: OverlayStyle {
        OverlayStyle.resolve(model.settings, forceOpaque: reduceTransparency || model.settings.overlayOpaque,
                             increasedContrast: contrast == .increased, backdropIsBright: layout?.backdropIsBright == true)
    }

    private var width: CGFloat? { forcedWidth ?? layout?.width }
    private var controlsVisible: Bool { (layout?.controlsVisible ?? revealed) || openControl != nil || toolbarFocused || previewControls }
    private var pointerInside: Bool { layout?.pointerInside ?? hoverInside }
    private var shouldAutoHide: Bool { !(layout?.pointerOnToolbar ?? hoverInside) && !toolbarFocused && openControl == nil && !previewControls }

    var body: some View {
        let style = self.style
        VStack(spacing: 0) {
            OverlayToolbar(openControl: $openControl, compact: (width ?? 880) < 640, onFocusChange: { toolbarFocused = $0 })
                .padding(.horizontal, 8)
                .frame(height: OverlayLayout.toolbarHeight)
                .background(theme.surface.opacity(0.98), in: RoundedRectangle(cornerRadius: theme.cardRadius))
                .overlay { RoundedRectangle(cornerRadius: theme.cardRadius).strokeBorder(theme.hairline, lineWidth: 1).opacity(controlsVisible ? 1 : 0).allowsHitTesting(false) }
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .disabled(!controlsVisible)
                .accessibilityHidden(!controlsVisible)
                .animation(LLMotion.hover(reduceMotion), value: controlsVisible)
                .contentShape(Rectangle())
                .onHover { if $0 { revealControls() } }
            block(style)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: LLMetrics.Radius.overlay, style: .continuous)
                        .fill(style.background.opacity(style.opacity))
                }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? LLMetrics.overlayMaxWidth : nil)
        .contentShape(Rectangle())
        .onHover { hoverInside = $0 }
        .contextMenu { contextMenu }
        .background(GeometryReader { geo in
            Color.clear.preference(key: OverlayHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(OverlayHeightKey.self) { height in
            let report = layout?.onHeightChange
            Task { @MainActor in report?(height) }
        }
        .onChange(of: layout?.pointerOnToolbar) { _, onTop in
            if onTop == true { revealControls() }
        }
        .onChange(of: controlsVisible, initial: true) { _, visible in
            layout?.controlsVisible = visible
        }
        .task(id: shouldAutoHide) {
            guard shouldAutoHide else { return }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, shouldAutoHide else { return }
            revealed = false
            layout?.controlsVisible = false
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func revealControls() {
        revealed = true
        layout?.controlsVisible = true
    }

    @ViewBuilder
    private var contextMenu: some View {
        @Bindable var settings = model.settings
        Button("显示字幕控制栏") { revealControls() }
        Button("隐藏字幕") { model.hideOverlay() }
        Button(model.overlayLocked ? "解锁浮层" : "锁定浮层") { model.toggleLock() }
        Divider()
        Button("透明背景") { settings.overlayOpaque = false; settings.overlayOpacity = 0 }
        Picker("对比模式", selection: $settings.overlayContrastMode) {
            ForEach(OverlayContrastMode.allCases) { Text($0.label).tag($0) }
        }
        Toggle("显示原文", isOn: $settings.showSourceInOverlay)
            .disabled(settings.captionPresentation == .singleLine)
        Toggle("显示上一句", isOn: $settings.showPreviousLine)
            .disabled(settings.captionPresentation == .singleLine)
        Toggle("显示呼吸线", isOn: $settings.showBreathLine)
            .disabled(settings.captionPresentation == .singleLine)
        Picker("字幕呈现", selection: $settings.captionPresentation) {
            ForEach(CaptionPresentation.allCases) { Text($0.label).tag($0) }
        }
        Picker("位置", selection: $settings.overlayPlacement) {
            ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
        }
        Divider()
        Button("字幕外观设置…") {
            settings.requestedSettingsTab = .appearance
            UnifiedSettingsPresentation.shared.open()
        }
        Button("恢复默认样式") { settings.resetOverlayStyle() }
    }

    private func block(_ style: OverlayStyle) -> some View {
        let lanes = model.settings.captionPresentation == .singleLine
            ? SingleLineCaptionContent.lane(from: model.lanes, tails: model.laneTails).map { [$0] } ?? []
            : model.lanes
        return VStack(alignment: .center, spacing: 20) {
            if lanes.isEmpty {
                LaneBlock(lane: nil, current: nil, previous: nil, settings: model.settings,
                          style: style, statusText: model.statusText, showsLabel: false, readingWidth: width)
            } else {
                ForEach(lanes) { lane in
                    let tail = model.laneTails[lane.id]
                    LaneBlock(lane: lane, current: tail?.current, previous: tail?.previous,
                              settings: model.settings, style: style,
                              statusText: laneStatus(lane, tail: tail), showsLabel: model.lanes.count > 1,
                              earlier: tail?.earlier, readingWidth: width)
                }
            }
        }
    }

    private func laneStatus(_ lane: LaneStatus, tail: LaneTail?) -> String {
        switch model.sessionState {
        case .paused: return "已暂停"
        case .reconnecting: return "重连中"
        case .completed: return "已结束"
        default: break
        }
        switch lane.capture.state {
        case .permissionRequired: return "需要权限"
        case .sourceUnavailable: return "\(lane.configuration.source.displayName) 已退出"
        case .waitingForAudio: return lane.configuration.source.kind == .microphone ? "等待你说话" : "等待发声"
        case .recovering: return "正在恢复"
        default: break
        }
        if let seg = tail?.current {
            if let lastGap = tail?.lastGap, lastGap.order > seg.order { return StatusCopy.gap(lastGap) }
            return StatusCopy.segment(seg)
        }
        return lane.capture.state == .capturing ? "正在听" : ""
    }
}
