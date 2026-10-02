import SwiftUI
import AppKit

/// Hex ⇄ Color for persisted user colors. Six hex digits, sRGB, no alpha (alpha is a separate setting).
enum HexColor {
    static func color(_ hex: String, fallback: Color) -> Color {
        guard let v = parse(hex) else { return fallback }
        return Color(hex: v)
    }

    static func parse(_ hex: String) -> UInt32? {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }

    static func hex(from color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int(round(max(0, min(1, ns.redComponent)) * 255))
        let g = Int(round(max(0, min(1, ns.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, ns.blueComponent)) * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Relative luminance, used to pick label/breath contrast against a custom background.
    static func luminance(_ hex: String) -> Double {
        guard let v = parse(hex) else { return 0 }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(Double((v >> 16) & 0xFF) / 255), g = lin(Double((v >> 8) & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// Resolved overlay palette for the current settings (§3.3 defaults, user overrides allowed).
struct OverlayStyle {
    var background: Color
    var opacity: Double
    var text: Color
    var source: Color
    var label: Color
    var breath: Color
    var hairline: Color
    var weight: Font.Weight
    var contrastMode: OverlayContrastMode
    var outlineHex: UInt32
    var outlineWidth: Double
    var increasedContrast = false

    func renderer(source isSource: Bool = false, size: Double, emphasis: Double = 1) -> CaptionTextRenderer {
        if contrastMode == .automatic {
            let foreground = HexColor.luminance(HexColor.hex(from: isSource ? source : text))
            let backdrop = HexColor.luminance(HexColor.hex(from: background))
            let contrast = (max(foreground, backdrop) + 0.05) / (min(foreground, backdrop) + 0.05)
            let readableEmphasis = foreground < 0.4 ? max(0.76, emphasis) : emphasis
            if opacity >= 0.95 && contrast >= 4.5 { return CaptionTextRenderer(edges: [], foregroundOpacity: readableEmphasis) }
            return .automatic(hex: HexColor.hex(from: isSource ? source : text), size: size, emphasis: readableEmphasis)
        }
        return CaptionTextRenderer(edges: [.init(hex: outlineHex, width: outlineWidth)])
    }

    /// Retain semantic hierarchy without letting moving imagery show through the letters.
    func secondaryOpacity(_ requested: Double) -> Double { increasedContrast ? max(0.8, requested) : requested }

    /// `forceOpaque` (Reduce Transparency, or the user's switch) makes the background opaque.
    /// `increasedContrast` is §3.3's high-contrast mode: an opaque scrim, pure white text when
    /// the translation colour is the default, the source at no less than 85%, the labels lifted.
    @MainActor
    static func resolve(_ s: AppSettings, forceOpaque: Bool, increasedContrast: Bool = false, backdropIsBright: Bool = false) -> OverlayStyle {
        let bg = HexColor.color(s.overlayBackgroundHex, fallback: Color(hex: 0x12110F))
        var text = HexColor.color(s.overlayTextHex, fallback: LLOverlay.text)
        let adaptiveDarkInk = backdropIsBright && s.overlayContrastMode == .automatic && !forceOpaque && !increasedContrast && s.overlayOpacity < 0.85
        if adaptiveDarkInk { text = Color(hex: 0x202124) }
        if increasedContrast, s.overlayTextHex.uppercased() == AppSettings.defaultOverlayTextHex { text = .white }
        let requestedOpacity = s.overlayOpacity.isFinite ? min(1, max(0, s.overlayOpacity)) : AppSettings.defaultOverlayOpacity
        let sourceAlpha = 0.72
        var source = s.overlaySourceHex.isEmpty ? text.opacity(sourceAlpha) : HexColor.color(s.overlaySourceHex, fallback: text.opacity(sourceAlpha))
        if adaptiveDarkInk { source = Color(hex: 0x44464A) }
        if increasedContrast, s.overlaySourceHex.isEmpty { source = text }
        let opacity = increasedContrast ? 1.0 : (forceOpaque ? 1.0 : requestedOpacity)
        let darkBackground = HexColor.luminance(s.overlayBackgroundHex) < 0.4
        let weight: Font.Weight
        switch s.overlayTextWeight {
        case .regular: weight = .regular
        case .medium: weight = .medium
        case .semibold: weight = .semibold
        }
        return OverlayStyle(
            background: bg,
            opacity: opacity,
            text: text,
            source: source,
            label: text.opacity(increasedContrast ? 0.75 : 0.55),
            breath: text,
            hairline: (darkBackground ? Color.white : Color.black).opacity((increasedContrast ? 0.12 : 0.06) * opacity),
            weight: weight,
            contrastMode: s.overlayContrastMode,
            outlineHex: HexColor.parse(s.overlayOutlineHex) ?? 0,
            outlineWidth: s.overlayOutlineWidth.isFinite ? min(3, max(0, s.overlayOutlineWidth)) : 0,
            increasedContrast: increasedContrast
        )
    }
}
