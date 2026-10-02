import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Design language §3. One warm neutral ground, one restrained accent, semantic colors only for
/// text. Every tint that sits on the paper (fills, tracks) has its own value per
/// appearance: an ink tint that reads at 5% on paper disappears on the dark ground.
struct LLTheme: Sendable, Equatable {
    var world: ExperienceTheme
    var isDark: Bool
    var ground: Color
    var surface: Color
    var sidebar: Color
    var ink: Color
    var ink2: Color
    var ink3: Color
    /// Long-form reading text (the transcript's translations): a step softer than `ink` on
    /// true black, where a near-white CJK stroke halates over a long read and looks heavier than
    /// its regular weight (#E6E9EE, ≈ 17 : 1); `ink` on paper and under Increase Contrast.
    var readingInk: Color
    /// Text of a disabled control: one token for the whole text tier, instead of an opacity
    /// that lands differently on every background.
    var inkDisabled: Color
    var hairline: Color
    /// Resting fill of a quiet (secondary) control.
    var fill: Color
    /// Hovered quiet control, hovered row.
    var fillHover: Color
    /// Pressed quiet control.
    var fillPressed: Color
    /// The idle part of a breath line and other faint tracks.
    var track: Color
    var accent: Color
    var moss: Color
    var ochre: Color
    var brick: Color

    static let wilds = LLTheme(
        world: .wilds,
        isDark: false,
        ground: Color(hex: 0xF3EFDF),
        surface: Color(hex: 0xFAF7EB),
        sidebar: Color(hex: 0xF3EFDF),
        ink: Color(hex: 0x263C32),
        ink2: Color(hex: 0x4E6153),
        ink3: Color(hex: 0x626D59),
        readingInk: Color(hex: 0x263C32),
        inkDisabled: Color(hex: 0x263C32, alpha: 0.35),
        hairline: Color(hex: 0x5E775B, alpha: 0.24),
        fill: Color(hex: 0x386B53, alpha: 0.07),
        fillHover: Color(hex: 0x386B53, alpha: 0.12),
        fillPressed: Color(hex: 0x386B53, alpha: 0.18),
        track: Color(hex: 0x386B53, alpha: 0.18),
        accent: Color(hex: 0x28644E),
        moss: Color(hex: 0x3F6843),
        ochre: Color(hex: 0x836428),
        brick: Color(hex: 0x963F31)
    )

    static let stellar = LLTheme(
        world: .stellar,
        isDark: true,
        ground: Color(hex: 0x030405),
        surface: Color(hex: 0x101114),
        sidebar: Color(hex: 0x030405),
        ink: Color(hex: 0xF2F3F5),
        ink2: Color(hex: 0xB9BDC6),
        ink3: Color(hex: 0x9299A5),
        readingInk: Color(hex: 0xE6E9EE),
        inkDisabled: Color(hex: 0xB9BDC6, alpha: 0.38),
        hairline: Color(hex: 0xD8DFEB, alpha: 0.17),
        fill: Color(hex: 0xD8DFEB, alpha: 0.055),
        fillHover: Color(hex: 0xD8DFEB, alpha: 0.10),
        fillPressed: Color(hex: 0xD8DFEB, alpha: 0.16),
        track: Color(hex: 0xD8DFEB, alpha: 0.18),
        accent: Color(hex: 0xDFE8F7),
        moss: Color(hex: 0x9CCDB3),
        ochre: Color(hex: 0xD8B98B),
        brick: Color(hex: 0xEC9E95)
    )

    // Existing render matrices keep their light/dark entry points.
    static let light = wilds
    static let dark = stellar
    var cardRadius: CGFloat { 10 }
    /// The accent as `RRGGBB`, for the pre-rendered particle sprites (which are keyed by hex).
    var accentHex: UInt32 { isDark ? 0xDFE8F7 : 0x28644E }
    /// Data light is distinct from the neutral material used for primary app actions.
    var starBlue: Color { isDark ? Color(hex: starBlueHex) : accent }
    /// `starBlue` as `RRGGBB`, for the pre-rendered halo sprites (the vocabulary map's hot words).
    var starBlueHex: UInt32 { isDark ? 0xA8C9F4 : accentHex }

    /// Increase Contrast (§11): the same paper with its tints lifted, so quiet controls, rows
    /// and hairlines have visible edges without any border being added.
    func increasedContrast() -> LLTheme {
        var t = self
        let up: Double = isDark ? 0.04 : 0
        t.readingInk = ink
        t.fill = ink.opacity(0.12 + up)
        t.fillHover = ink.opacity(0.16 + up)
        t.fillPressed = ink.opacity(0.20 + up)
        t.hairline = ink.opacity(0.28 + up)
        t.track = ink.opacity(0.20 + up)
        return t
    }
}

extension LLTheme {
    /// Whether this is the Increase Contrast variant of its theme. Read from the theme itself, not
    /// from `colorSchemeContrast`, so a surface rendered with a forced theme (the offscreen
    /// fixtures) answers the same as the window, where `ThemedRoot` applies the variant.
    var raisesContrast: Bool { self == increasedContrast() }
}

/// Overlay palette is fixed dark regardless of system appearance (§3.3).
enum LLOverlay {
    static let scrim = Color(hex: 0x12110F, alpha: 0.84)
    static let scrimOpaque = Color(hex: 0x12110F, alpha: 0.96)
    static let text = Color(hex: 0xF4F0E8)
    static let text2 = Color(hex: 0xF4F0E8, alpha: 0.70)
    static let label = Color(hex: 0xF4F0E8, alpha: 0.55)
    static let hairline = Color.white.opacity(0.06)
    static let breath = Color(hex: 0xF4F0E8)
    static let accent = Color(hex: 0xD7745A)
}

private struct LLThemeKey: EnvironmentKey {
    static let defaultValue: LLTheme = .stellar
}

private struct ExperienceSettingsKey: EnvironmentKey {
    static let defaultValue: AppSettings? = nil
}

extension EnvironmentValues {
    var experienceSettings: AppSettings? {
        get { self[ExperienceSettingsKey.self] }
        set { self[ExperienceSettingsKey.self] = newValue }
    }
    var theme: LLTheme {
        get { self[LLThemeKey.self] }
        set { self[LLThemeKey.self] = newValue }
    }
}

/// Resolves the theme from the color scheme once at the root, so previews can force either.
/// Increase Contrast lifts the tints (see `increasedContrast()`).
struct ThemedRoot<Content: View>: View {
    @Environment(\.experienceSettings) private var inheritedSettings
    @Environment(\.colorSchemeContrast) private var contrast
    var settings: AppSettings? = nil
    var forced: LLTheme? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let settings = settings ?? inheritedSettings
        let base = forced ?? (settings?.experienceTheme == .wilds ? LLTheme.wilds : .stellar)
        let theme = contrast == .increased ? base.increasedContrast() : base
        content()
            .environment(\.theme, theme)
            .environment(\.experienceSettings, settings)
            .tint(theme.accent)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
