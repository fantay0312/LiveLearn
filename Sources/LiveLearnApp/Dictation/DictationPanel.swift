import AppKit
import SwiftUI
import Observation
import QuartzCore

final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class DictationHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

@MainActor @Observable
final class DictationPresentation {
    var visible = false
}

enum DictationPanelLayout {
    static func size(text: String, notice: String?) -> CGSize {
        let measured = (String(text.suffix(120)) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
        return CGSize(width: min(736, max(264, min(560, measured) + 176)).rounded(.up), height: notice == nil ? 56 : 94)
    }

    static func frame(size: CGSize, near target: CGRect?, screen: CGRect) -> CGRect {
        let width = min(size.width, max(0, screen.width - 24))
        let height = min(size.height, max(0, screen.height - 24))
        let x = target.map { $0.minX } ?? (screen.midX - width / 2)
        var y = target.map { $0.minY - height - 12 } ?? (screen.minY + 28)
        if let target, y < screen.minY + 12 { y = target.maxY + 12 }
        return CGRect(x: min(max(x, screen.minX + 12), screen.maxX - width - 12),
                      y: min(max(y, screen.minY + 12), screen.maxY - height - 12), width: width, height: height)
    }
}

@MainActor
final class DictationPanelController {
    let panel: DictationPanel
    private weak var controller: DictationController?
    private let presentation = DictationPresentation()
    private var dismissal: Task<Void, Never>?
    private var displayGeneration = UUID()
    private var visible = false

    init(controller: DictationController) {
        self.controller = controller
        panel = DictationPanel(contentRect: NSRect(x: 0, y: 0, width: 216, height: 56),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("LiveLearn.dictation")
        panel.title = "LiveLearn 语音输入"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.contentView = nil
        observe()
    }

    private func mount() {
        guard panel.contentView == nil, let controller else { return }
        panel.contentView = DictationHostingView(rootView: DictationHUD(controller: controller, presentation: presentation))
    }

    private func observe() {
        withObservationTracking {
            _ = controller?.text; _ = controller?.notice; _ = controller?.phase
            _ = controller?.targetFrame; _ = controller?.settings.nearInput
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.visible { self.place(animated: true) }
                self.observe()
            }
        }
    }

    private func place(animated: Bool) {
        guard let controller else { return }
        let anchor = controller.settings.nearInput ? controller.targetFrame : nil
        let location = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) ?? NSScreen.main else { return }
        let content = controller.text.isEmpty ? (controller.phase == .listening ? "开始说话…" : controller.phase.title) : controller.text
        let frame = DictationPanelLayout.frame(size: DictationPanelLayout.size(text: content, notice: controller.notice), near: anchor, screen: screen.visibleFrame)
        guard frame != panel.frame else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }

    func show() {
        let wasVisible = visible && panel.isVisible
        dismissal?.cancel(); displayGeneration = UUID(); visible = true
        let id = displayGeneration
        panel.ignoresMouseEvents = false
        mount(); place(animated: false)
        panel.orderFrontRegardless()
        if wasVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            presentation.visible = true
        } else {
            presentation.visible = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, self.visible, self.displayGeneration == id else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) { self.presentation.visible = true }
            }
        }
    }

    func hide(immediately: Bool = false) {
        dismissal?.cancel(); displayGeneration = UUID()
        let id = displayGeneration
        visible = false; panel.ignoresMouseEvents = true
        let instant = immediately || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(instant ? nil : .easeOut(duration: 0.22)) { presentation.visible = false }
        if instant { unmount(); return }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard let self, self.displayGeneration == id else { return }
            self.unmount()
        }
    }

    private func unmount() { panel.orderOut(nil); panel.contentView = nil }

    func dismissAfterSuccess() {
        dismissal?.cancel()
        let id = displayGeneration
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.displayGeneration == id else { return }
            self.hide()
        }
    }
}

private struct DictationMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

struct DictationHUD: View {
    let controller: DictationController
    let presentation: DictationPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                action("xmark", label: "取消语音输入") { controller.cancel() }
                if controller.phase == .correcting || controller.phase == .finishing || (controller.phase == .starting && controller.meter.level == 0) {
                    ProgressView().controlSize(.small).tint(.white).frame(width: 44, height: 32)
                        .accessibilityLabel(controller.phase.title)
                } else if controller.delivered {
                    Image(systemName: controller.deliveryConfirmed ? "checkmark.circle.fill" : "arrow.down.to.line").foregroundStyle(.white)
                        .frame(width: 44, height: 32).accessibilityLabel(controller.deliveryConfirmed ? "已输入到 \(controller.targetName)" : "已发送粘贴到 \(controller.targetName)")
                } else if controller.phase == .selectingInput {
                    Image(systemName: "text.cursor").foregroundStyle(.white)
                        .frame(width: 44, height: 32)
                } else {
                    HStack(alignment: .center, spacing: 4) {
                        ForEach(Array(controller.meter.heights.enumerated()), id: \.offset) { _, height in
                            Capsule().fill(.white).frame(width: 5, height: height)
                        }
                    }
                    .frame(width: 44, height: 32)
                    .animation(reduceMotion ? nil : .linear(duration: 0.07), value: controller.meter)
                    .accessibilityLabel("麦克风音量")
                    .accessibilityValue("\(Int(controller.meter.level * 100))%")
                }
                Text(label).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(controller.text.isEmpty ? 0.7 : 0.95))
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(controller.text.isEmpty ? controller.phase.title : controller.text)
                if controller.phase == .listening {
                    action("checkmark", label: "完成语音输入") { controller.finish() }
                } else if !controller.text.isEmpty, !controller.isActive, !controller.deliveryConfirmed {
                    action("doc.on.doc", label: "复制听写结果") { controller.copyResult() }
                }
            }
            .padding(.horizontal, 12).frame(height: 56)
            if let notice = controller.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).frame(height: 30, alignment: .top).padding(.bottom, 8)
            }
        }
        .background { DictationMaterial().overlay(.black.opacity(0.88)).allowsHitTesting(false) }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.14), lineWidth: 1).allowsHitTesting(false) }
        .scaleEffect(presentation.visible || reduceMotion ? 1 : 0.92)
        .opacity(presentation.visible ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var label: String {
        if controller.phase == .correcting { return "纠错中…" }
        if controller.phase == .finishing { return "正在确认…" }
        if controller.text.isEmpty { return controller.phase == .listening ? "开始说话…" : controller.phase.title }
        return String(controller.text.suffix(120))
    }

    private func action(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85)).frame(width: 32, height: 32)
                .background(.white.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}
