import AppKit
import SwiftUI
import Testing
@testable import LiveLearnApp

@MainActor
struct OverlayReadabilityTests {
    @Test func layoutChoicesPersistAndResetWithoutErasingOtherBehavior() {
        withSettings { settings, defaults in
            settings.overlayTextAlignment = .leading
            settings.overlayLineSpacing = .relaxed
            settings.showSourceInOverlay = false
            settings.controlSessionOnOverlayClose = false
            let restored = AppSettings(defaults: defaults)
            #expect(restored.overlayTextAlignment == .leading && restored.overlayLineSpacing == .relaxed)
            restored.resetOverlayStyle()
            #expect(restored.overlayTextAlignment == .center && restored.overlayLineSpacing == .standard)
            #expect(!restored.showSourceInOverlay && !restored.controlSessionOnOverlayClose)
        }
    }

    @Test func presetsAreExplicitAndReadablePaperNeedsNoHalo() {
        withSettings { settings, defaults in
            settings.overlayTextHex = "334455"
            #expect(AppSettings(defaults: defaults).overlayTextHex == "334455")
            OverlayAppearancePreset.paper.apply(to: settings)
            let style = OverlayStyle.resolve(settings, forceOpaque: false)
            #expect(style.opacity == 0.96)
            #expect(style.renderer(size: 28).shadowHex == nil)
            #expect(settings.overlayFontFamily == "Songti SC")
            #expect(settings.overlayLineSpacing == .relaxed)
            OverlayAppearancePreset.clear.apply(to: settings)
            #expect(settings.overlayOpacity == 0 && settings.overlayTextHex == "FFFFFF")
            #expect(settings.overlayFontFamily.isEmpty)
            let renderer = OverlayStyle.resolve(settings, forceOpaque: false).renderer(size: 26)
            #expect(renderer.shadowRadius <= 2.2 && renderer.shadowOpacity <= 0.9)
            #expect(renderer.edges.isEmpty)
        }
    }

    @Test func previewUsesActualSavedWidthWithSafeBounds() {
        #expect(CaptionPreviewSurface.layoutWidth(880) == 880)
        #expect(CaptionPreviewSurface.layoutWidth(480) == 480)
        #expect(CaptionPreviewSurface.layoutWidth(1400) == 1400)
        #expect(CaptionPreviewSurface.layoutWidth(.nan) == AppSettings.defaultOverlayWidth)
    }

    private func withSettings(_ body: (AppSettings, UserDefaults) throws -> Void) rethrows {
        let suite = "LiveLearn.testing.contrast.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppSettings(defaults: defaults), defaults)
    }

    @Test func automaticContrastKeepsSolidTextWithoutOutlining() {
        withSettings { settings, _ in
            settings.overlayTextHex = "000000"
            settings.overlaySourceHex = "FFFFFF"
            let style = OverlayStyle.resolve(settings, forceOpaque: false)
            #expect(style.opacity == 0)
            #expect(HexColor.hex(from: style.text) == "000000")
            #expect(HexColor.hex(from: style.source) == "FFFFFF")
            #expect(style.renderer(size: 26).edges.isEmpty)
            #expect(style.renderer(size: 26).shadowHex == 0xFFFFFF)
            #expect(style.renderer(source: true, size: 17).shadowHex == 0)
            // Mid-grey must choose black by measured contrast, not an arbitrary 0.4 threshold.
            #expect(CaptionTextRenderer.contrastingHex("808080") == 0)
            #expect(CaptionTextRenderer.contrastingHex("000000") == 0xFFFFFF)
            #expect(CaptionTextRenderer.contrastingHex("FFCC00") == 0)
        }
    }

    @Test func switchingModesAndRelaunchKeepManualStyle() {
        withSettings { settings, defaults in
            settings.overlayFontFamily = "Kaiti SC"
            settings.overlayTextHex = "000000"
            settings.overlaySourceHex = "33BB88"
            settings.overlayOutlineHex = "FFFFFF"
            settings.overlayOutlineWidth = 2.25
            settings.overlayContrastMode = .manual
            settings.overlayContrastMode = .automatic
            settings.overlayContrastMode = .manual
            let restored = AppSettings(defaults: defaults)
            #expect(restored.overlayFontFamily == "Kaiti SC")
            #expect(restored.overlayTextHex == "000000" && restored.overlaySourceHex == "33BB88")
            let renderer = OverlayStyle.resolve(restored, forceOpaque: false).renderer(size: 26)
            #expect(renderer.edges == [.init(hex: 0xFFFFFF, width: 2.25)])
            restored.resetOverlayStyle()
            #expect(restored.overlayFontFamily.isEmpty && restored.overlayContrastMode == .automatic)
            #expect(restored.overlayOutlineWidth == 0 && restored.overlaySourceHex.isEmpty)
        }
    }

    @Test func installedKaiFontReallyResolvesAndMissingFontFallsBack() {
        if let family = OverlayTypography.kaiFamily {
            let font = OverlayTypography.nativeFont(family: family, size: 32, weight: .regular)
            #expect(font.familyName == family || font.fontName == family)
            #expect(font.pointSize == 32)
        }
        let fallback = OverlayTypography.nativeFont(family: "LiveLearn-Missing-Font", size: 26, weight: .medium)
        #expect(fallback == NSFont.systemFont(ofSize: 26, weight: .medium))
    }

    @Test func invalidSettingsStaySafeAndAccessibilityKeepsSourceColor() {
        withSettings { settings, _ in
            settings.overlayContrastMode = .manual
            settings.overlayOutlineWidth = .infinity
            settings.overlayTextHex = "invalid"
            settings.overlaySourceHex = "008800"
            let style = OverlayStyle.resolve(settings, forceOpaque: false, increasedContrast: true)
            #expect(style.opacity == 1 && style.outlineWidth == 0)
            #expect(HexColor.hex(from: style.source) == "008800")
            settings.overlayOutlineWidth = -12
            #expect(OverlayStyle.resolve(settings, forceOpaque: false).outlineWidth == 0)
        }
    }

    @Test func automaticTextKeepsSolidGlyphInteriorsAndTransparentPanel() throws {
        func bitmap(mode: OverlayContrastMode) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content:
                Text("楷体 Black 字幕")
                    .font(.system(size: 26)).foregroundStyle(.black)
                    .textRenderer(mode == .automatic ? .automatic(hex: "000000", size: 26) : CaptionTextRenderer(edges: []))
                    .frame(width: 360, height: 90))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let automatic = try bitmap(mode: .automatic)
        let manual = try bitmap(mode: .manual)
        var automaticPixels = 0
        var manualPixels = 0
        var shadowPixels = 0
        var opaqueBlackInteriorPixels = 0
        for y in 0..<automatic.pixelsHigh {
            for x in 0..<automatic.pixelsWide {
                let color = try #require(automatic.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent > 0.5 {
                    automaticPixels += 1
                }
                if color.alphaComponent > 0.05 && color.redComponent > 0.9 { shadowPixels += 1 }
                let plain = manual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                if let plain, plain.alphaComponent > 0.99 && plain.redComponent < 0.01 {
                    opaqueBlackInteriorPixels += 1
                    #expect(color.alphaComponent > 0.99 && color.redComponent < 0.01)
                }
                if (manual.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { manualPixels += 1 }
                if x < 12 || y < 12 || x >= automatic.pixelsWide - 12 || y >= automatic.pixelsHigh - 12 {
                    #expect(color.alphaComponent == 0)
                }
            }
        }
        #expect(automaticPixels > manualPixels)
        #expect(shadowPixels > 100 && opaqueBlackInteriorPixels > 100)
        #expect(automaticPixels < automatic.pixelsHigh * automatic.pixelsWide / 3)
    }
}
