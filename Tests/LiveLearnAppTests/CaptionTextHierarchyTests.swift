import Testing
import Foundation
import AppKit
import SwiftUI
import CaptionDomain
@testable import LiveLearnApp

@MainActor
struct CaptionTextHierarchyTests {
    @Test func brightBackgroundUsesSolidDarkInkInsteadOfHollowWhiteOutlines() throws {
        func bitmap(_ renderer: CaptionTextRenderer, inkAlpha: Double) throws -> NSBitmapImageRep {
            let view = Text("上一句与原文 Previous sentence")
                .font(.system(size: 17, weight: .medium)).foregroundStyle(Color.white.opacity(inkAlpha))
                .textRenderer(renderer).frame(width: 360, height: 60).background(Color.white)
            let image = ImageRenderer(content: view)
            image.scale = 2
            return NSBitmapImageRep(cgImage: try #require(image.cgImage))
        }
        let old = try bitmap(.init(edges: [], shadowHex: 0, shadowRadius: 0.8, shadowOpacity: 0.68), inkAlpha: 0.48)
        let suite = "LiveLearn.testing.adaptive-contrast.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let bright = OverlayStyle.resolve(settings, forceOpaque: false, backdropIsBright: true)
        let dark = OverlayStyle.resolve(settings, forceOpaque: false, backdropIsBright: false)
        #expect(HexColor.hex(from: bright.text) == "202124")
        #expect(HexColor.hex(from: dark.text) == settings.overlayTextHex)
        #expect(bright.opacity == dark.opacity && bright.renderer(size: 17).edges.isEmpty)
        let image = ImageRenderer(content: Text("上一句与原文 Previous sentence")
            .font(.system(size: 17, weight: .medium)).foregroundStyle(bright.text)
            .textRenderer(bright.renderer(size: 17, emphasis: 0.48))
            .frame(width: 360, height: 60).background(Color.white))
        image.scale = 2
        let protected = NSBitmapImageRep(cgImage: try #require(image.cgImage))
        func darkPixels(_ bitmap: NSBitmapImageRep) -> Int {
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent < 0.65 { count += 1 }
                }
            }
            return count
        }
        #expect(darkPixels(protected) > darkPixels(old) + 800)
        let renderer = CaptionTextRenderer.automatic(hex: "FFFFFF", size: 17, emphasis: 0.48)
        #expect(renderer.foregroundOpacity == 0.48 && renderer.edges.isEmpty)
    }

    @Test func backdropToneIgnoresFlashesAndHoldsItsStateAroundTheThreshold() {
        var tone = CaptionBackdropTone()
        let values = [0.9, 0.2, 0.9, 0.9, 0.5, 0.55, 0.6, 0.65, 0.2, 0.2, .nan]
        let observed = values.map { tone.update(luminance: $0) }
        #expect(observed == [false, false, false, true, true, true, true, true, true, false, false])
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
