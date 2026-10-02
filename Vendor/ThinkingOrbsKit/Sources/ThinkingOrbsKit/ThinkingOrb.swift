// The SwiftUI ThinkingOrb.
//
// TimelineView(.animation) drives the clock and Canvas does the drawing —
// no timers, no Metal, no CADisplayLink to tear down. SwiftUI stops
// servicing a TimelineView that is off-screen, which is the equivalent of
// the web build's IntersectionObserver pause and comes for free.

import SwiftUI

/// Theme mode. `.auto` follows the environment's colour scheme.
public enum OrbTheme: Sendable {
    case auto, dark, light
}

@available(iOS 15.0, macOS 12.0, *)
public struct ThinkingOrb: View {
    private let state: OrbState
    private let size: OrbSize
    private let theme: OrbTheme
    private let speed: Double
    private let paused: Bool
    private let displaySize: Double?
    private let ringSegments: Int?
    private let particleScale: Double
    private let interactionPoint: CGPoint?
    private let interactionStrength: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // ImageRenderer never advances a TimelineView, so snapshot.sh injects a
    // fixed instant here to capture a deterministic frame.
    @Environment(\.orbFrozenTime) private var frozenTime

    /// `displaySize` renders the orb at an arbitrary point size while keeping
    /// the tuned `size` preset's geometry — the drawing is scaled inside the
    /// Canvas, so it stays vector-crisp at any factor (a `scaleEffect` would
    /// rasterise the layer first). Mirrors the React Native port's prop.
    public init(
        state: OrbState = .working,
        size: OrbSize = .px64,
        theme: OrbTheme = .auto,
        speed: Double = 1,
        paused: Bool = false,
        displaySize: Double? = nil,
        ringSegments: Int? = nil,
        particleScale: Double = 1,
        interactionPoint: CGPoint? = nil,
        interactionStrength: Double = 0
    ) {
        self.state = state
        self.size = size
        self.theme = theme
        self.speed = speed
        self.paused = paused
        self.displaySize = displaySize
        self.ringSegments = ringSegments
        self.particleScale = particleScale.isFinite ? min(1, max(0.15, particleScale)) : 1
        self.interactionPoint = interactionPoint
        self.interactionStrength = interactionStrength.isFinite ? min(1, max(0, interactionStrength)) : 0
    }

    private var isDark: Bool {
        switch theme {
        case .dark: return true
        case .light: return false
        case .auto: return colorScheme == .dark
        }
    }

    public var body: some View {
        let preset = resolvePreset(state, size, ringSegments: ringSegments)
        let effSpeed = preset.speed * speed
        let side = displaySize ?? size.value

        Group {
            if let frozenTime {
                // Raw engine time, NOT scaled by speed: the golden vectors and
                // the web parity harness both evaluate the engine at this t
                // directly, so applying the preset speed here would compare
                // two different instants and report a false mismatch.
                canvas(preset: preset, t: frozenTime)
            } else if reduceMotion || paused {
                // one static, deterministic frame — same instant as the web
                canvas(preset: preset, t: OrbSpec.reducedMotionT * effSpeed)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused)) { timeline in
                    // One shared clock, so several orbs on screen stay in
                    // phase exactly as they do on the web.
                    let t = timeline.date.timeIntervalSinceReferenceDate * effSpeed
                    canvas(preset: preset, t: t)
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private func canvas(preset: ResolvedPreset, t: Double) -> some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            var context = context
            let zoom = (displaySize ?? size.value) / size.value
            if zoom != 1 { context.scaleBy(x: zoom, y: zoom) }
            let frame = orbFrame(preset, size: size.value, t: t)
            // lines first, so nodes sit on top of their edges
            for l in frame.lines {
                var path = Path()
                path.move(to: CGPoint(x: l.x1, y: l.y1))
                path.addLine(to: CGPoint(x: l.x2, y: l.y2))
                context.stroke(
                    path,
                    with: .color(ink(l.white, l.a)),
                    lineWidth: l.w
                )
            }
            if state == .breathing && ringSegments != nil {
                // The large, fine-particle rendition uses bounded shade batches.
                // Defaults retain the original z-sorted painter and golden snapshots.
                var shades: [Int: Path] = [:]
                for d in frame.dots {
                    let gray = min(31, max(0, Int((d.white * 31).rounded())))
                    let alpha = min(7, max(0, Int((d.a * 7).rounded())))
                    let key = gray * 8 + alpha
                    let radius = d.r * particleScale
                    let point = displaced(x: d.x, y: d.y)
                    shades[key, default: Path()].addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius,
                                                                      width: radius * 2, height: radius * 2))
                }
                for key in shades.keys.sorted() {
                    context.fill(shades[key]!, with: .color(ink(Double(key / 8) / 31, Double(key % 8) / 7)))
                }
            } else {
                // dots are already z-sorted into draw order by the engine
                for d in frame.dots {
                    let radius = d.r * particleScale
                    let rect = CGRect(x: d.x - radius, y: d.y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(ink(d.white, d.a)))
                }
            }
        }
    }

    private func displaced(x: Double, y: Double) -> CGPoint {
        guard let point = interactionPoint, point.x.isFinite, point.y.isFinite, interactionStrength > 0 else { return CGPoint(x: x, y: y) }
        let dx = point.x * size.value - x, dy = point.y * size.value - y
        let influence = exp(-(dx * dx + dy * dy) / pow(size.value * 0.28, 2)) * interactionStrength * 0.20
        let limit = size.value * 0.035
        return CGPoint(x: x + min(limit, max(-limit, dx * influence)), y: y + min(limit, max(-limit, dy * influence)))
    }

    /// Quantise to 8-bit exactly as the canvas painter does, so the platforms
    /// land on identical greys rather than merely close ones.
    private func ink(_ white: Double, _ alpha: Double) -> Color {
        let w = Swift.min(1, Swift.max(0, white))
        let g = ((isDark ? 1 - w : w) * 255).rounded(.toNearestOrAwayFromZero) / 255
        return Color(.sRGB, red: g, green: g, blue: g, opacity: alpha)
    }
}

// MARK: - Frozen time (snapshot testing)

private struct OrbFrozenTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// Pins the animation to a fixed instant. Used by the snapshot harness;
    /// `ImageRenderer` does not fire `onAppear` or advance `TimelineView`,
    /// so without this every capture would render the same t=0 frame.
    var orbFrozenTime: Double? {
        get { self[OrbFrozenTimeKey.self] }
        set { self[OrbFrozenTimeKey.self] = newValue }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension View {
    /// Freeze every ThinkingOrb below this view at `t` seconds.
    public func orbFrozenTime(_ t: Double?) -> some View {
        environment(\.orbFrozenTime, t)
    }
}
