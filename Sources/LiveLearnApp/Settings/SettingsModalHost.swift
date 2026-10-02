import AppKit
import SwiftUI

/// The in-window settings modal. Open: the dim and the card fade in over 240 ms on the enter
/// curve, the card rising 6 pt; close: both fade over 160 ms with no movement. The 4 pt blur
/// under it is switched, never interpolated (every intermediate radius would re-blur the whole
/// window), and stays on until the close fade has finished so Home is never un-blurred while
/// the card is still visible. Reduce Motion snaps both ways; Reduce Transparency uses no blur
/// and a 50% dim. `presentation.dismiss()` semantics (first responder and input gating) stay
/// immediate; only the picture lags.
struct SettingsModalHost: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// Lags `isPresented` by the exit fade so the overlay can animate out.
    @State private var shown = false
    /// On from the first presented frame, off once the close fade has completed.
    @State private var blurred = false
    private var presentation: UnifiedSettingsPresentation { .shared }

    private var dim: Double { reduceTransparency ? 0.5 : (theme.isDark ? 0.34 : 0.28) }

    func body(content: Content) -> some View {
        content
            // The page under the modal holds still: the blur below is then rendered once, not
            // once per particle frame. The modal's own rail is outside this subtree.
            .environment(\.ambientMotionPaused, blurred || presentation.isPresented)
            .blur(radius: blurred && !reduceTransparency ? 4 : 0)
            .disabled(presentation.isPresented)
            .allowsHitTesting(!presentation.isPresented)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(presentation.isPresented)
            .overlay {
                // The reader stays mounted (it is only layout); the dim and the card come and
                // go inside it, each with its own transition.
                GeometryReader { geometry in
                    let rect = LiveLearnSettingsPage.modalRect(in: CGRect(origin: .zero, size: geometry.size))
                    ZStack {
                        if shown {
                            Color.black.opacity(dim)
                                .contentShape(Rectangle())
                                .onTapGesture { presentation.dismiss() }
                                .accessibilityHidden(true)
                                .transition(.opacity)
                            card(in: rect)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .allowsHitTesting(presentation.isPresented)
                .onExitCommand { if presentation.isPresented { presentation.dismiss() } }
            }
            .background {
                if !staticRender { SettingsHostWindowReader() }
            }
            .onAppear {
                shown = presentation.isPresented
                blurred = presentation.isPresented
            }
            .onChange(of: presentation.isPresented) { _, presented in
                if presented {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { blurred = true }
                    withAnimation(LLMotion.enter(reduceMotion, 0.24)) { shown = true }
                } else {
                    withAnimation(LLMotion.exit(reduceMotion, 0.16), completionCriteria: .logicallyComplete) {
                        shown = false
                    } completion: {
                        // A re-open during the fade keeps the blur.
                        guard !presentation.isPresented else { return }
                        var still = Transaction()
                        still.disablesAnimations = true
                        withTransaction(still) { blurred = false }
                    }
                }
            }
    }

    /// The card: radius 14 (the overlay step of the radius scale; it was an off-scale 16) with
    /// the floating material's edge (round 12, `LLTheme.floatingEdge`): in the dark, `ink` lit
    /// from above — the same light as the paper menu's 0.5 pt edge (`floatingPaper`), drawn at
    /// 1 pt because this sheet is the size of the window; on paper and under Increase Contrast
    /// the even `hairline`. A drop shadow only on the light ground — on the black ground it is
    /// invisible under the dim and would cost an offscreen pass on every frame of the fades and
    /// of the rail.
    ///
    /// The shadow is a leaf *behind* the card, not a modifier wrapped around it. Branching on
    /// `theme.isDark` around the card itself (`Group { if dark { card } else { card.shadow() } }`)
    /// gives the two branches different types, so SwiftUI treats a theme change as a removal and
    /// an insertion and resets every `@State` under `SettingsView` — and the theme is switched
    /// from inside that very subtree, on the 主题 page. As an `if` with no `else` inside
    /// `.background`, only this rounded rectangle appears and disappears; `SettingsView` keeps
    /// one identity in both themes, and the dark card still pays no offscreen pass at all. The
    /// shape matches the card's clip exactly, so the cast silhouette is unchanged. The edge is a
    /// shape style, not a branch, for the same reason.
    private func card(in rect: CGRect) -> some View {
        let shape = RoundedRectangle(cornerRadius: LLMetrics.Radius.overlay, style: .continuous)
        return SettingsView()
            .frame(width: rect.width, height: rect.height)
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.floatingEdge(contrast: contrast), lineWidth: 1) }
            .background {
                if !theme.isDark {
                    shape.fill(theme.ground)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                }
            }
            .position(x: rect.midX, y: rect.midY)
    }
}

/// The ✕: a glyph action (13 pt regular `xmark`, `ink3` lifting to `ink` under the pointer) in
/// a 32 pt square — no plate, the weight of the page's other glyphs rather than the medium one
/// it had. `SettingsView` puts it on the rail's brand line.
struct SettingsModalCloseButton: View {
    static let side: CGFloat = 32
    let close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 13))
                .frame(width: Self.side, height: Self.side).contentShape(Rectangle())
        }
        .buttonStyle(GlyphButtonStyle(tint: theme.ink3))
        .accessibilityLabel("关闭设置")
        .help("关闭设置 · Esc")
        .keyboardShortcut(.cancelAction)
    }
}

private struct SettingsHostWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsHostBindingView { SettingsHostBindingView() }
    func updateNSView(_ view: SettingsHostBindingView, context: Context) {}
}

/// Reads geometry and window lifetime without changing the main window's chrome.
final class SettingsHostBindingView: NSView {
    private var observers: [NSObjectProtocol] = []
    private var closeKeyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let closeKeyMonitor { NSEvent.removeMonitor(closeKeyMonitor) }
        closeKeyMonitor = nil
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { UnifiedSettingsPresentation.shared.hostClosed() }
                    else { UnifiedSettingsPresentation.shared.dismiss() }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didHideNotification,
                                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UnifiedSettingsPresentation.shared.dismiss() }
        })
        closeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            let handled = MainActor.assumeIsolated {
                if event.window === window, UnifiedSettingsPresentation.shared.isPresented,
                   event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                   event.charactersIgnoringModifiers == "w" {
                    UnifiedSettingsPresentation.shared.dismiss()
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            UnifiedSettingsPresentation.shared.register(window)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

}
