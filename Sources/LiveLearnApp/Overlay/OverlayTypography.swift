import AppKit
import SwiftUI

enum OverlayTextAlignment: String, CaseIterable, Identifiable {
    case center, leading
    var id: String { rawValue }
    var label: String { self == .center ? "居中" : "左对齐" }
    var horizontal: HorizontalAlignment { self == .center ? .center : .leading }
    var text: TextAlignment { self == .center ? .center : .leading }
    var frame: Alignment { self == .center ? .center : .leading }
}

enum OverlayLineSpacing: String, CaseIterable, Identifiable {
    case compact, standard, relaxed
    var id: String { rawValue }
    var label: String { switch self { case .compact: "紧凑"; case .standard: "适中"; case .relaxed: "舒展" } }
    var multiplier: Double { switch self { case .compact: 0.65; case .standard: 1; case .relaxed: 1.5 } }
}

enum OverlayAppearancePreset: String, CaseIterable, Identifiable {
    case clear, paper, kai
    var id: String { rawValue }
    var label: String { switch self { case .clear: "通透白字"; case .paper: "纸感阅读"; case .kai: "楷体墨字" } }
    @MainActor var family: String { switch self { case .clear: ""; case .paper: "Songti SC"; case .kai: OverlayTypography.kaiFamily ?? "" } }
    @MainActor var isAvailable: Bool { self != .kai || OverlayTypography.kaiFamily != nil }
    var note: String { switch self {
        case .clear: "系统字体、白字、透明背景，适合视频字幕"
        case .paper: "宋体、暖白背景、深色文字，适合长时间阅读"
        case .kai: "楷体、墨色文字、透明背景，适合浅色画面"
    } }
    @MainActor func apply(to settings: AppSettings) {
        guard isAvailable else { return }
        settings.overlayFontFamily = family
        settings.overlayTextHex = self == .clear ? "FFFFFF" : "24211D"
        settings.overlaySourceHex = ""
        settings.overlayTextWeight = self == .clear ? .medium : .regular
        settings.captionTargetSize = self == .clear ? 26 : 28
        settings.captionSourceSize = 17
        settings.overlayBackgroundHex = self == .paper ? "F4F0E8" : AppSettings.defaultOverlayBackgroundHex
        settings.overlayOpacity = self == .paper ? 0.96 : 0
        settings.overlayOpaque = false
        settings.overlayContrastMode = .automatic
        settings.overlayLineSpacing = self == .paper ? .relaxed : .standard
    }

    @MainActor func matches(_ settings: AppSettings) -> Bool {
        isAvailable && settings.overlayFontFamily == family
            && settings.overlayTextHex == (self == .clear ? "FFFFFF" : "24211D")
            && settings.overlaySourceHex.isEmpty
            && settings.overlayTextWeight == (self == .clear ? .medium : .regular)
            && settings.captionTargetSize == (self == .clear ? 26 : 28)
            && settings.captionSourceSize == 17
            && settings.overlayBackgroundHex == (self == .paper ? "F4F0E8" : AppSettings.defaultOverlayBackgroundHex)
            && settings.overlayOpacity == (self == .paper ? 0.96 : 0)
            && !settings.overlayOpaque && settings.overlayContrastMode == .automatic
            && settings.overlayLineSpacing == (self == .paper ? .relaxed : .standard)
    }
}

enum OverlayContrastMode: String, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "自动对比" : "手动样式" }
}

/// Use installed families only. A missing font falls back without changing the saved choice.
@MainActor
enum OverlayTypography {
    static let families: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    static var kaiFamily: String? {
        ["Kaiti SC", "STKaiti", "KaiTi", "Kaiti TC", "楷体"].first { family in
            NSFont(name: family, size: 26) != nil || families.contains(family)
        }
    }

    static func label(_ family: String) -> String {
        if family.isEmpty { return "系统字体" }
        if ["Kaiti SC", "STKaiti", "KaiTi", "楷体"].contains(family) { return "楷体 · \(family)" }
        if family == "Kaiti TC" { return "楷体（繁体）" }
        if family == "Songti SC" { return "宋体 · Songti SC" }
        return family
    }

    static func nativeFont(family: String, size: Double, weight: Font.Weight) -> NSFont {
        let size = size.isFinite ? min(80, max(8, size)) : 26
        let nsWeight: NSFont.Weight = weight == .semibold ? .semibold : (weight == .medium ? .medium : .regular)
        if !family.isEmpty {
            let managerWeight = weight == .semibold ? 8 : (weight == .medium ? 6 : 5)
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: managerWeight, size: size) {
                return font
            }
            if let font = NSFont(name: family, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: nsWeight)
    }

    static func font(_ settings: AppSettings, size: Double, weight: Font.Weight = .regular) -> Font {
        Font(nativeFont(family: settings.overlayFontFamily, size: size, weight: weight))
    }
}
