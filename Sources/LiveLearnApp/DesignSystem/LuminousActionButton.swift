import SwiftUI

/// A quiet action with a living cloud around its perimeter, sharing the scene's material.
///
/// Live on Home the light — the breathing glow and the halo — draws with Metal
/// (`ControlLightScene`, its own display link, no SwiftUI render pass); only the transient
/// ripple and the busy spinner stay on `LuminousMotion` clocks, active while they show. A
/// static render, a frozen time, Reduce Motion, a machine without a GPU or a caller on
/// `.canvas` gets the clocked Canvas stack, which stays the reference.
///
/// The capsule is almost clear: a breath of ink for a body and a thin rim lit from above, the
/// side that faces the core — brightest on the top arc, fading toward the bottom, brighter on
/// hover and focus. Increase Contrast trades the lit rim for an even one. Every primary state
/// (start, pause, resume, the busy words) has one width, so the capsule never changes size or
/// leaves the axis; Stop is a bare text action with quieter stars. On paper there is no
/// breathing glow — the light theme takes no radial fill — and the orbit is crisp forest dots.
struct LuminousActionButton: View {
    let appearance: SessionActionAppearance
    var active = true
    var frozenTime: Double? = nil
    var previewRipple: Double? = nil
    var previewPressed = false
    var previewHovered = false
    var previewReducedMotion = false
    var activationTime: Date? = nil
    var renderer: AmbientRenderer = .canvas
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceTransparency) private var opaque
    @FocusState private var keyboardFocused: Bool
    @State private var hovering = false
    @State private var clickID = 0
    @State private var rippleStarted: Date?
    @State private var latched = false
    @State private var inheritedPulseActive = false

    /// The primary capsule's one width. The breathing glow is a single point sprite capped at
    /// 511 px: 184 pt needs 429 px at 2× (see `ControlLightScene`).
    nonisolated static let capsuleWidth: CGFloat = 184
    nonisolated static let stopWidth: CGFloat = 80

    /// The light's tint: the core's pearl on the dark sky, the forest accent on paper.
    private var tint: Color { theme.isDark ? Color(hex: 0xE3F0F6) : theme.accent }
    private var reduceMotion: Bool { systemReduceMotion || previewReducedMotion }
    private var isStop: Bool { appearance == .stop }
    private var foreground: Color {
        guard enabled else { return theme.ink3 }
        return isStop && !highlighted ? HomeInk(theme).value : theme.ink
    }
    private var height: CGFloat { 48 }
    private var width: CGFloat { isStop ? Self.stopWidth : Self.capsuleWidth }
    private var breathes: Bool { !isStop && enabled && !appearance.isBusy }
    /// The breathing glow is a radial fill: dark only.
    private var glows: Bool { !isStop && theme.isDark }
    private var highlighted: Bool { hovering || previewHovered || keyboardFocused }
    private var haloStrength: Double { !enabled ? 0.20 : (isStop ? (highlighted ? 0.60 : 0.18) : (highlighted ? 1.0 : 0.85)) }

    @ViewBuilder
    var body: some View {
        if staticRender || frozenTime != nil {
            control
        } else {
            control.focused($keyboardFocused)
        }
    }

    private var control: some View {
        Button {
            guard enabled && !appearance.isBusy && !latched else { return }
            latched = true
            rippleStarted = Date()
            clickID += 1
            action()
        } label: {
            // Only the light lives on the clock. The capsule, the label and the focus ring are
            // ordinary static views, so a frame re-evaluates two canvases and nothing else.
            let living = active && (enabled || appearance.isBusy) && (breathes || appearance.isBusy || highlighted || rippleStarted != nil || inheritedPulseActive)
            ZStack {
                if !isStop { capsule }
                if let metal = AmbientRendering.metalRenderer(for: renderer, layer: .button, staticRender: staticRender, frozenTime: frozenTime, reduceMotion: reduceMotion) {
                    // The glow and the halo in one Metal layer on the light's clock; the ripple
                    // alone keeps a SwiftUI clock, and only while it runs (0.65 s).
                    SpriteLayerView(renderer: metal, scene: ControlLightScene(
                        glows: glows, inset: isStop ? 0 : 4, breathes: breathes,
                        emphasized: highlighted, dimmed: !enabled || appearance.isBusy,
                        haloStrength: haloStrength, haloSpeed: appearance.isBusy ? 1.9 : 1,
                        glowTint: AmbientRendering.components(tint),
                        haloTint: theme.isDark ? AmbientRendering.components(hex: 0xD9EDF3) : AmbientRendering.components(theme.accent),
                        halos: theme.isDark, active: living))
                        .padding(.horizontal, isStop ? 0 : -4)
                        .allowsHitTesting(false)
                    LuminousMotion(active: active && (rippleStarted != nil || inheritedPulseActive || previewRipple != nil)) { _ in
                        if let progress = rippleProgress {
                            RippleSurface(progress: progress, color: tint).clipShape(Capsule())
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                LuminousMotion(active: living, frozenTime: frozenTime) { time in
                    let breath = reduceMotion || !breathes ? 0.25 : (1 - cos(time * .pi * 2 / 4.6)) / 2
                    ZStack {
                        if glows {
                            ControlBreathingLight(phase: breath, color: tint, emphasized: highlighted, dimmed: !enabled || appearance.isBusy)
                                .clipShape(Capsule())
                        }
                        NebulaHalo(time: reduceMotion ? 0 : time * (appearance.isBusy ? 1.9 : 1), strength: haloStrength)
                            .padding(.horizontal, isStop ? 0 : -4)
                        if let progress = rippleProgress {
                            RippleSurface(progress: progress, color: tint).clipShape(Capsule())
                        }
                    }
                }
                .allowsHitTesting(false)
                }
                HStack(spacing: 8) {
                    if appearance.isBusy {
                        LuminousMotion(active: living, frozenTime: frozenTime) { time in
                            Circle().trim(from: 0, to: 0.68).stroke(foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                                .frame(width: 12, height: 12)
                                .rotationEffect(.radians(reduceMotion ? 0 : time * 4.8))
                        }
                        .frame(width: 16, height: 24)
                    } else {
                        Image(systemName: appearance.symbol).font(.system(size: isStop ? 9 : 11, weight: .regular))
                            .foregroundStyle(isStop || !enabled ? foreground : theme.accent)
                            .frame(width: 16, height: 24)
                    }
                    Text(appearance.title).font(isStop ? LLFont.body : LLFont.heading)
                        .foregroundStyle(foreground).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, isStop ? 12 : 16)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
            .overlay {
                if keyboardFocused && enabled {
                    Capsule().strokeBorder(theme.accent.opacity(0.65), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(LuminousPressStyle(previewPressed: previewPressed, reduceOverride: previewReducedMotion))
        .disabled(appearance.isBusy || latched)
        .onHover { hovering = $0 }
        .task(id: clickID) {
            guard clickID > 0 else { return }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            latched = false
            rippleStarted = nil
        }
        .task(id: activationTime) {
            guard let activationTime else { inheritedPulseActive = false; return }
            let remaining = 0.65 - Date().timeIntervalSince(activationTime)
            guard remaining > 0 else { inheritedPulseActive = false; return }
            inheritedPulseActive = true
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            inheritedPulseActive = false
        }
        .accessibilityLabel(appearance.title)
        .accessibilityValue(appearance.isBusy ? "处理中" : (enabled ? "" : "不可用"))
    }

    /// The capsule's body and rim. The rim is lit from the top arc (the core's side) and fades to
    /// a trace at the bottom; hover and focus lift it, a disabled capsule keeps 40 % of it.
    /// Under Increase Contrast it is an even 1 pt ink rim instead. The body is a breath of ink on
    /// the sky and clear on paper, where any tint and a closed outline read as a form button —
    /// there the lower arc dissolves into the page. Opaque graphite under Reduce Transparency.
    private var capsule: some View {
        let lift = highlighted && enabled ? 1.6 : 1.0
        let dim = enabled ? 1.0 : 0.4
        let rim = theme.accent
        let (top, middle, bottom) = theme.isDark ? (0.20, 0.08, 0.05) : (0.22, 0.08, 0.03)
        return ZStack {
            Capsule().fill(opaque ? theme.surface : (theme.isDark ? theme.ink.opacity(0.03) : .clear))
            if theme.raisesContrast {
                Capsule().strokeBorder(theme.ink.opacity(0.45 * dim), lineWidth: 1)
            } else {
                Capsule().strokeBorder(LinearGradient(stops: [
                    .init(color: rim.opacity(top * lift * dim), location: 0),
                    .init(color: rim.opacity(middle * lift * dim), location: 0.5),
                    .init(color: rim.opacity(bottom * lift * dim), location: 1)
                ], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
        }
    }

    private var rippleProgress: Double? {
        guard !reduceMotion else { return nil }
        if let previewRipple { return min(1, max(0, previewRipple)) }
        guard let began = [rippleStarted, activationTime].compactMap({ $0 }).max() else { return nil }
        let progress = Date().timeIntervalSince(began) / 0.65
        return progress < 1 ? max(0, progress) : nil
    }
}

/// A stationary elliptical pool of light inhales and exhales; the label never flickers.
/// (Internal so the parity render can put the Canvas light next to `ControlLightScene`.)
struct ControlBreathingLight: View {
    let phase: Double
    let color: Color
    let emphasized: Bool
    let dimmed: Bool

    var body: some View {
        Canvas { context, size in
            let p = min(1, max(0, phase))
            let alpha = ((emphasized ? 0.075 : 0.028) + p * 0.115) * (dimmed ? 0.30 : 1)
            var glow = context
            glow.scaleBy(x: 1, y: 0.28)
            let center = CGPoint(x: size.width * 0.47, y: size.height * 0.54 / 0.28)
            glow.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: size.height / 0.28)),
                      with: .radialGradient(Gradient(stops: [
                        .init(color: color.opacity(alpha), location: 0),
                        .init(color: color.opacity(alpha * 0.68), location: 0.4),
                        .init(color: .clear, location: 1)
                      ]), center: center, startRadius: 0, endRadius: size.width * (0.46 + p * 0.12)))
        }
        .accessibilityHidden(true)
    }
}

private struct LuminousPressStyle: ButtonStyle {
    var previewPressed: Bool
    var reduceOverride: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || previewPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion && !reduceOverride ? 0.97 : 1)
            .brightness(pressed ? 0.035 : 0)
            .animation(reduceMotion || reduceOverride ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: pressed ? 0.10 : 0.25), value: pressed)
    }
}

private struct RippleSurface: View {
    let progress: Double
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            let eased = 1 - pow(1 - progress, 3)
            let diameter = geometry.size.width * 2.2 * eased
            Circle().fill(color.opacity(0.10 * (1 - progress)))
                .overlay { Circle().stroke(color.opacity(0.45 * (1 - progress)), lineWidth: 1) }
                .frame(width: diameter, height: diameter)
                .position(x: geometry.size.width * 0.22, y: geometry.size.height / 2)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
