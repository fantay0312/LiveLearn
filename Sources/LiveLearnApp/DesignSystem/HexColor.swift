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
    static func luminance(_ hex: String) -> Double { parse(hex).map(luminance) ?? 0 }

    static func luminance(_ v: UInt32) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(Double((v >> 16) & 0xFF) / 255), g = lin(Double((v >> 8) & 0xFF) / 255), b = lin(Double(v & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// `amount` of the way from `a` to `b`, channel by channel: a solid tint instead of an
    /// opacity, so the result reads the same over any picture.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(1, max(0, amount))
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((a >> shift) & 0xFF), to = Double((b >> shift) & 0xFF)
            return UInt32((from + (to - from) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
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

    /// On the plate the glyphs are drawn plain whenever the plate alone carries them; anything
    /// drawn off it (`onPlate: false`, the line under the plate) or on a plate too clear to do
    /// that gets the automatic edge. Manual style is the user's own outline everywhere.
    func renderer(source isSource: Bool = false, size: Double, emphasis: Double = 1, onPlate: Bool = true) -> CaptionTextRenderer {
        guard contrastMode == .automatic else { return CaptionTextRenderer(edges: [.init(hex: outlineHex, width: outlineWidth)]) }
        let ink = HexColor.hex(from: isSource ? source : text)
        let readableEmphasis = HexColor.luminance(ink) < 0.4 ? max(0.76, emphasis) : emphasis
        if onPlate, plateCarries(ink) { return CaptionTextRenderer(edges: [], lineOpacity: readableEmphasis) }
        return .automatic(hex: ink, size: size, emphasis: readableEmphasis)
    }

    /// Whether the plate keeps `ink` at 4.5 : 1 over the frame that is worst for it: a white
    /// frame showing through under light ink, a black one under dark ink.
    func plateCarries(_ ink: String) -> Bool {
        let worst: UInt32 = CaptionTextRenderer.contrastingHex(ink) == 0 ? 0xFFFFFF : 0x000000
        let ground = HexColor.luminance(HexColor.mix(worst, HexColor.parse(HexColor.hex(from: background)) ?? 0, opacity))
        let foreground = HexColor.luminance(ink)
        return (max(foreground, ground) + 0.05) / (min(foreground, ground) + 0.05) >= 4.5
    }

    /// The least plate an unlocked caption stands on while the pointer is over it.
    static let grabOpacity = 0.34

    /// The block's fill. A caption that can be moved shows it under the pointer: a clear block
    /// gets a plate of the tone opposite its ink, a faint one is lifted to `grabOpacity`. The
    /// plate says the caption can be picked up, and it is what takes the press: a window's
    /// transparent pixels let a click fall through to whatever is underneath.
    func plate(grabbable: Bool) -> Color {
        guard grabbable, opacity < Self.grabOpacity else { return background.opacity(opacity) }
        let tone = opacity > 0 ? background : Color(hex: CaptionTextRenderer.contrastingHex(HexColor.hex(from: text)))
        return tone.opacity(Self.grabOpacity)
    }

    /// Retain semantic hierarchy without letting moving imagery show through the letters.
    func secondaryOpacity(_ requested: Double) -> Double { increasedContrast ? max(0.8, requested) : requested }

    /// `forceOpaque` (Reduce Transparency, or the user's switch) makes the background opaque.
    /// `increasedContrast` is §3.3's high-contrast mode: an opaque plate and the labels lifted.
    ///
    /// Every ink is solid. The source follows the translation as a tint of it (a quarter of the
    /// way to the opposite tone) unless the user gave it its own colour, and the labels are a
    /// further step quieter; an opacity instead would let the picture, or the edge drawn under
    /// the glyphs, show through them.
    @MainActor
    static func resolve(_ s: AppSettings, forceOpaque: Bool, increasedContrast: Bool = false) -> OverlayStyle {
        let bg = HexColor.color(s.overlayBackgroundHex, fallback: Color(hex: 0x12110F))
        let ink = HexColor.parse(s.overlayTextHex) ?? HexColor.parse(AppSettings.defaultOverlayTextHex) ?? 0xFFFFFF
        let tone = CaptionTextRenderer.contrastingHex(String(format: "%06X", ink))
        let text = Color(hex: ink)
        let requestedOpacity = s.overlayOpacity.isFinite ? min(1, max(0, s.overlayOpacity)) : AppSettings.defaultOverlayOpacity
        let source = HexColor.parse(s.overlaySourceHex).map { Color(hex: $0) }
            ?? Color(hex: increasedContrast ? ink : HexColor.mix(ink, tone, 0.24))
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
            label: Color(hex: HexColor.mix(ink, tone, increasedContrast ? 0.2 : 0.34)),
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
