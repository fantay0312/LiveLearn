import AppKit
import SwiftUI

enum ExplorationDestination: Int, CaseIterable {
    case home, records, vocabulary, settings, sources, language, engine, models, appearance, shortcuts, privacy, diagnostics

    var symbol: String {
        switch self {
        case .home: "house"
        case .records: "clock"
        case .vocabulary: "book.closed"
        case .settings: "gearshape"
        case .sources: "waveform"
        case .language: "character.bubble"
        case .engine: "cpu"
        case .models: "externaldrive"
        case .appearance: "textformat"
        case .shortcuts: "command"
        case .privacy: "lock"
        case .diagnostics: "stethoscope"
        }
    }

    var planetColor: Color {
        let colors: [UInt32] = [0x70BEED, 0xC4C1B8, 0xC47A56, 0xCEBD95, 0x7DBCC9, 0xCAA6C9,
                                0xE2B382, 0x8EAADE, 0xB9A0D8, 0x85BDC4, 0x9FC5A7, 0xDDB391]
        return Color(hex: colors[rawValue])
    }

    static func settingsTab(_ tab: SettingsTab) -> Self {
        switch tab {
        case .theme: .home
        case .sources: .sources
        case .language: .language
        case .engine: .engine
        case .localModels: .models
        case .appearance: .appearance
        case .shortcuts: .shortcuts
        case .privacy: .privacy
        case .diagnostics: .diagnostics
        case .vocabulary: .vocabulary
        case .browserExtension: .language
        case .textTranslation: .language
        case .dictation: .sources
        case .modules: .sources
        }
    }
}

/// Native vector destinations stay sharp at sidebar, navigation and hero sizes.
struct DestinationEmblem: View {
    let destination: ExplorationDestination
    var size: CGFloat = 36
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if theme.world == .stellar { planet }
            else { landmark }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var planet: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [.white, destination.planetColor, destination.planetColor.opacity(0.65), Color(hex: 0x081321)],
                                     center: .init(x: 0.2, y: 0.16), startRadius: 0, endRadius: size * 0.84))
                .overlay {
                    Canvas { context, bounds in
                        for i in 0..<5 {
                            let y = bounds.height * (0.15 + Double(i) * 0.16)
                            let rect = CGRect(x: -bounds.width * 0.16, y: y, width: bounds.width * 1.3, height: bounds.height * 0.22)
                            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.11)), lineWidth: max(0.5, size * 0.025))
                        }
                    }
                    .rotationEffect(.degrees(-26))
                    .clipShape(Circle())
                }
                .overlay { Circle().strokeBorder(destination.planetColor.opacity(0.7), lineWidth: 0.6) }
                .padding(size * 0.12)
            if destination == .records || destination == .home || destination == .models {
                Ellipse().stroke(destination.planetColor.opacity(0.65), lineWidth: max(0.7, size * 0.022))
                    .frame(width: size * 1.03, height: size * 0.32)
                    .rotationEffect(.degrees(-28))
            }
        }
        .shadow(color: destination.planetColor.opacity(0.17), radius: size * 0.13, y: 2)
    }

    private var landmark: some View {
        ZStack {
            CompassRose().stroke(theme.accent.opacity(0.45), lineWidth: 0.8)
            Circle().fill(theme.surface).padding(size * 0.15)
            Circle().stroke(theme.ochre.opacity(0.6), lineWidth: 0.8).padding(size * 0.11)
            Image(systemName: destination.symbol)
                .font(.system(size: size * 0.34, weight: .medium))
                .foregroundStyle(theme.accent)
        }
    }
}

private struct CompassRose: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        for i in 0..<16 {
            let angle = Double(i) * .pi / 8 - .pi / 2
            let radius = min(rect.width, rect.height) * (i.isMultiple(of: 2) ? 0.5 : 0.30)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// One bounded timeline drives the scene. No timers per star, particle, or decoration.
/// `frozenTime` is a deterministic render hook; static fixtures and Reduce Motion don't tick.
struct ExplorationBackdrop: View {
    var immersive = false
    var frozenTime: TimeInterval? = nil
    var onDestination: ((ExplorationDestination) -> Void)? = nil
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var epoch = Date()

    private var paused: Bool { frozenTime != nil || staticRender || reduceMotion || scenePhase != .active }

    var body: some View {
        Group {
            if immersive {
                GeometryReader { geometry in
                    Group {
                    if staticRender || frozenTime != nil {
                        Image(nsImage: ExplorationWorldModel.snapshot(world: theme.world, size: geometry.size, time: frozenTime ?? 0))
                            .resizable()
                    } else {
                        ExplorationWorldView(world: theme.world, motionEnabled: !reduceMotion && scenePhase == .active,
                                             onDestination: onDestination)
                    }
                    }
                    .overlay {
                        if theme.world == .wilds {
                            LinearGradient(stops: [.init(color: theme.ground, location: 0),
                                                   .init(color: theme.ground.opacity(0.95), location: 0.30),
                                                   .init(color: theme.ground.opacity(0.78), location: 0.46),
                                                   .init(color: .clear, location: 0.70)],
                                           startPoint: .leading, endPoint: .trailing)
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { timeline in
            let time = frozenTime ?? (staticRender || reduceMotion ? 0 : timeline.date.timeIntervalSince(epoch))
            GeometryReader { geometry in
                ZStack {
                    theme.ground
                    SceneAtmosphere(world: theme.world, time: time, subtle: true)
                }
                .clipped()
            }
        }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(immersive && !staticRender)
    }
}

private struct SceneAtmosphere: View {
    let world: ExperienceTheme
    let time: TimeInterval
    let subtle: Bool

    var body: some View {
        Canvas { context, size in
            if world == .stellar { drawStars(in: &context, size: size) }
            else { drawWind(in: &context, size: size) }
        }
    }

    private func drawStars(in context: inout GraphicsContext, size: CGSize) {
        let count = subtle ? 32 : 95
        for i in 0..<count {
            let seed = Double(i)
            let x = (seed * 137.507 + time * (0.8 + Double(i % 3) * 0.35)).truncatingRemainder(dividingBy: max(size.width, 1))
            let y = (seed * 83.71 + sin(time / 9 + seed) * 7).truncatingRemainder(dividingBy: max(size.height, 1))
            let alpha = (0.26 + (sin(time * 0.6 + seed * 2.3) + 1) * 0.23) * (subtle ? 0.35 : 1)
            let radius = i % 9 == 0 ? 1.6 : 0.75
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: radius * 2, height: radius * 2)),
                         with: .color(Color(hex: 0xC5E8FF).opacity(alpha)))
        }
        guard !subtle else { return }
        let center = CGPoint(x: size.width * 0.77, y: size.height * 0.44)
        let radius = size.width * 0.19
        var orbit = Path()
        orbit.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius * 0.38,
                                   width: radius * 2, height: radius * 0.76))
        context.stroke(orbit, with: .color(Color(hex: 0x91BED8).opacity(0.16)), style: StrokeStyle(lineWidth: 0.65, dash: [3, 9]))
        let angle = time / 18
        let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius * 0.38)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                     with: .color(Color(hex: 0xEFCCA3).opacity(0.85)))
    }

    private func drawWind(in context: inout GraphicsContext, size: CGSize) {
        for i in 0..<(subtle ? 18 : 38) {
            let seed = Double(i)
            let x = (seed * 139.17 + time * (4 + Double(i % 4))).truncatingRemainder(dividingBy: max(size.width, 1))
            let y = size.height * 0.25 + (seed * 61.1).truncatingRemainder(dividingBy: max(size.height * 0.7, 1)) + sin(time / 3 + seed) * 12
            let alpha = (0.18 + (sin(time + seed) + 1) * 0.09) * (subtle ? 0.35 : 1)
            let rect = CGRect(x: x, y: y, width: i % 3 == 0 ? 4 : 2, height: 2)
            context.fill(Path(ellipseIn: rect), with: .color(Color(hex: i % 3 == 0 ? 0x48785D : 0xB6984E).opacity(alpha)))
        }
        guard !subtle else { return }
        var mistContext = context
        mistContext.addFilter(.blur(radius: 14))
        for layer in 0..<3 {
            var mist = Path()
            let drift = sin(time / 9 + Double(layer)) * 45
            let y = size.height * (0.50 + Double(layer) * 0.17)
            mist.move(to: CGPoint(x: size.width * 0.48 + drift, y: y))
            mist.addCurve(to: CGPoint(x: size.width + 60 + drift, y: y - 25),
                          control1: CGPoint(x: size.width * 0.67, y: y - 42),
                          control2: CGPoint(x: size.width * 0.79, y: y + 34))
            mistContext.stroke(mist, with: .color(Color(hex: 0xFFFFF1).opacity(0.20)),
                           style: StrokeStyle(lineWidth: 14 + Double(layer) * 7, lineCap: .round))
        }
    }
}

struct ExperienceThemeToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ExperienceTheme.allCases) { item in
                let selected = model.settings.experienceTheme == item
                Button { model.settings.experienceTheme = item } label: {
                    Text(item.shortTitle).font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? theme.ink : theme.ink2)
                    .frame(width: 42, height: 28)
                    .background(selected ? theme.fill : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(InlineButtonStyle())
                .accessibilityLabel("切换到\(item.title)主题")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(item.note)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("探索主题")
    }
}
