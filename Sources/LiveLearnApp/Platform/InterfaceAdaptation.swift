import AppKit
import SwiftUI

enum InterfaceSize: String, CaseIterable, Identifiable {
    case automatic, standard, large, larger, largest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动适配屏幕"
        case .standard: "100%"
        case .large: "125%"
        case .larger: "150%"
        case .largest: "175%"
        }
    }
    var factor: CGFloat? {
        switch self {
        case .automatic: nil
        case .standard: 1
        case .large: 1.25
        case .larger: 1.5
        case .largest: 1.75
        }
    }
}

enum InterfaceLayout {
    static func scale(for screen: CGRect, preference: InterfaceSize) -> CGFloat {
        let automatic = min(1.5, max(1, (screen.height / 950 * 8).rounded() / 8))
        let fitting = min((screen.width - 32) / LLMetrics.minWindow.width,
                          (screen.height - 48) / LLMetrics.minWindow.height)
        return max(0.5, min(preference.factor ?? automatic, fitting))
    }

    static func windowFrame(current: CGRect, screen: CGRect, scale: CGFloat, automatic: Bool, preferredSize: CGSize? = nil) -> CGRect {
        let available = screen.insetBy(dx: 16, dy: 16)
        let desired = automatic ? CGSize(width: LLMetrics.defaultWindow.width * scale, height: LLMetrics.defaultWindow.height * scale) : preferredSize ?? current.size
        let size = CGSize(width: min(available.width, max(LLMetrics.minWindow.width * scale, desired.width)),
                          height: min(available.height, max(LLMetrics.minWindow.height * scale, desired.height)))
        let origin = CGPoint(x: current.midX - size.width / 2, y: current.maxY - size.height)
        return CGRect(x: min(max(origin.x, available.minX), available.maxX - size.width),
                      y: min(max(origin.y, available.minY), available.maxY - size.height), width: size.width, height: size.height)
    }
}

struct InterfaceWindowSizing: Codable {
    var automatic: Bool
    var preferredSize: CGSize?

    init(restoredSize: CGSize) {
        automatic = abs(restoredSize.width - LLMetrics.defaultWindow.width) < 4 &&
            (abs(restoredSize.height - LLMetrics.defaultWindow.height) < 4 || abs(restoredSize.height - LLMetrics.defaultWindow.height - 28) < 4)
        preferredSize = automatic ? nil : restoredSize
    }

    mutating func userResized(to size: CGSize) { automatic = false; preferredSize = size }
}

private struct InterfaceScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var interfaceScale: CGFloat {
        get { self[InterfaceScaleKey.self] }
        set { self[InterfaceScaleKey.self] = newValue }
    }
}

/// Keep layout and hit testing in the same logical coordinates, including embedded AppKit views.
struct AdaptiveInterface<Content: View>: View {
    let preference: InterfaceSize
    @ViewBuilder var content: () -> Content
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            content()
                .environment(\.interfaceScale, scale)
                .frame(width: geometry.size.width / scale, height: geometry.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .frame(minWidth: LLMetrics.minWindow.width * scale, minHeight: LLMetrics.minWindow.height * scale)
        .background(InterfaceWindowReader(preference: preference, scale: $scale))
    }
}

private struct InterfaceWindowReader: NSViewRepresentable {
    let preference: InterfaceSize
    @Binding var scale: CGFloat

    func makeNSView(context: Context) -> InterfaceWindowBinding {
        let view = InterfaceWindowBinding()
        view.changed = { scale = $0 }
        view.preference = preference
        return view
    }
    func updateNSView(_ view: InterfaceWindowBinding, context: Context) {
        view.changed = { scale = $0 }
        if view.preference != preference {
            view.preference = preference
            view.scheduleUpdate()
        }
    }
    static func dismantleNSView(_ view: InterfaceWindowBinding, coordinator: ()) { view.detach() }
}

final class InterfaceWindowBinding: NSView {
    var preference = InterfaceSize.automatic
    var changed: ((CGFloat) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var sizing: InterfaceWindowSizing?
    private var sizingKey: String?
    private var lastScreen: CGRect?
    private var lastScale: CGFloat?
    private var scheduled = false
    private var initialized = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.didExitFullScreenNotification { self?.lastScreen = nil }
                    self?.scheduleUpdate()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window else { return }
                self.sizing?.userResized(to: window.frame.size)
                self.saveSizing()
            }
        })
        scheduleUpdate()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        lastScreen = nil; lastScale = nil
        initialized = false
    }

    func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        guard let window, let screen = window.screen else { return }
        if !initialized {
            let key = "interface.windowSizing.\(window.identifier?.rawValue ?? "main")"
            sizingKey = key
            let stored = UserDefaults.standard.data(forKey: key)
            sizing = stored.flatMap { try? JSONDecoder().decode(InterfaceWindowSizing.self, from: $0) } ?? InterfaceWindowSizing(restoredSize: window.frame.size)
            saveSizing()
            initialized = true
        }
        let visible = screen.visibleFrame
        let scale = InterfaceLayout.scale(for: visible, preference: preference)
        guard lastScreen != visible || lastScale != scale else { return }
        lastScreen = visible; lastScale = scale
        changed?(scale)
        guard !window.styleMask.contains(.fullScreen) else { return }
        let frame = InterfaceLayout.windowFrame(current: window.frame, screen: visible, scale: scale,
            automatic: sizing?.automatic ?? true, preferredSize: sizing?.preferredSize)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    private func saveSizing() {
        guard let sizingKey, let sizing, let data = try? JSONEncoder().encode(sizing) else { return }
        UserDefaults.standard.set(data, forKey: sizingKey)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
