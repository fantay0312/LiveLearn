import Testing
import Foundation
import AppKit
import SwiftUI
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct CaptionTextHierarchyTests {
    /// Pixels a light-ink line darkens on a white frame: the halo that makes it readable there.
    private func darkPixels(_ renderer: CaptionTextRenderer, ink: Color, size: Double) throws -> Int {
        let image = ImageRenderer(content: Text("上一句与原文 Previous sentence")
            .font(.system(size: size, weight: .medium)).foregroundStyle(ink)
            .textRenderer(renderer).frame(width: 520, height: 80).background(Color.white))
        image.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.7 { count += 1 }
            }
        }
        return count
    }

    @Test func theInkIsTheUsersOnEveryFrameAndTheHaloCarriesItOverBrightOnes() throws {
        let suite = "LiveLearn.testing.constant-ink.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let style = OverlayStyle.resolve(settings, forceOpaque: false)
        #expect(HexColor.hex(from: style.text) == settings.overlayTextHex)
        #expect(style.opacity == 0 && style.renderer(size: 26).haloHex == 0)
        // White ink on a white frame is the worst case; even the quietest context line (60 %)
        // keeps a dark edge there, where the single faint shadow it replaces left next to none.
        let faint = CaptionTextRenderer(edges: [], haloHex: 0, halos: [.init(radius: 0.8, opacity: 0.45, y: 1)], lineOpacity: 0.6)
        let before = try darkPixels(faint, ink: style.text, size: 17)
        let quiet = try darkPixels(style.renderer(size: 17, emphasis: 0.6), ink: style.text, size: 17)
        let current = try darkPixels(style.renderer(size: 26), ink: style.text, size: 26)
        #expect(quiet > 1_000 && before < quiet / 10)
        #expect(current > quiet * 3)
        // Dark ink gets the opposite halo; emphasis fades the line as a whole, never its geometry.
        settings.overlayTextHex = "24211D"
        let ink = OverlayStyle.resolve(settings, forceOpaque: false).renderer(size: 26, emphasis: 0.48)
        #expect(ink.haloHex == 0xFFFFFF && ink.lineOpacity == 0.76 && ink.edges.isEmpty)
        #expect(ink.halos == CaptionTextRenderer.automatic(hex: "24211D", size: 26).halos)
    }

    @Test func anUnlockedCaptionShowsAPlateUnderThePointerAndKeepsTheUsersOwn() throws {
        let suite = "LiveLearn.testing.caption-plate.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        func plate(_ grabbable: Bool) throws -> NSColor {
            try #require(NSColor(OverlayStyle.resolve(settings, forceOpaque: false).plate(grabbable: grabbable)).usingColorSpace(.sRGB))
        }
        #expect(try plate(false).alphaComponent == 0)
        var held = try plate(true)
        #expect(abs(held.alphaComponent - OverlayStyle.grabOpacity) < 0.01 && held.redComponent < 0.01)
        settings.overlayTextHex = "24211D"
        held = try plate(true)
        #expect(abs(held.alphaComponent - OverlayStyle.grabOpacity) < 0.01 && held.redComponent > 0.99)
        settings.overlayBackgroundHex = "F4F0E8"
        settings.overlayOpacity = 0.1
        held = try plate(true)
        #expect(abs(held.alphaComponent - OverlayStyle.grabOpacity) < 0.01 && HexColor.hex(from: Color(nsColor: held.withAlphaComponent(1))) == "F4F0E8")
        settings.overlayOpacity = 0.6
        #expect(try abs(plate(true).alphaComponent - 0.6) < 0.01 && plate(true) == plate(false))
    }

    @Test func automaticContrastKeepsRequestedHierarchyAndOnlyAccessibilityRaisesIt() {
        let suite = "LiveLearn.testing.caption-hierarchy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let ordinary = OverlayStyle.resolve(settings, forceOpaque: false)
        #expect(ordinary.secondaryOpacity(0.48) == 0.48)
        #expect(ordinary.secondaryOpacity(0.68) == 0.68)
        let accessible = OverlayStyle.resolve(settings, forceOpaque: true, increasedContrast: true)
        #expect(accessible.opacity == 1 && accessible.secondaryOpacity(0.48) >= 0.8)
        #expect(ordinary.opacity == 0)
    }

    @Test func ReadingSlotsKeepCurrentLineStillAsHistoryAndIncomingAppear() throws {
        let suite = "LiveLearn.testing.caption-slots.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showPreviousLine = true
        settings.showSourceInOverlay = true
        let style = OverlayStyle.resolve(settings, forceOpaque: false)
        let segments = SampleData.runningSnapshot(includeGap: false).captions.segments
        let current = try #require(segments.last)
        let previous = try #require(segments.dropLast().last)
        func height(current: CaptionDomain.CaptionSegment?, previous: CaptionDomain.CaptionSegment?) -> CGFloat {
            let host = NSHostingView(rootView: LaneBlock(lane: nil, current: current, previous: previous,
                                                       settings: settings, style: style, statusText: "", readingWidth: 880)
                .frame(width: 832).environment(\.staticRender, true))
            return host.fittingSize.height
        }
        let empty = height(current: nil, previous: nil)
        let first = height(current: previous, previous: nil)
        let live = height(current: current, previous: previous)
        #expect(abs(empty - first) < 1 && abs(first - live) < 1)
    }
}
