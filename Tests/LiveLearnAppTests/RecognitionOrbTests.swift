import CoreGraphics
import SwiftUI
import Testing
@testable import LiveLearnApp

@MainActor
struct RecognitionOrbTests {
    @Test func recognitionAloneUsesTheTextFreeAnimation() {
        #expect(RecognitionOrb.replacesStatus("识别中"))
        for status in ["已暂停", "重连中", "需要权限", "正在恢复", "已结束", "未完成", "翻译中", ""] {
            #expect(!RecognitionOrb.replacesStatus(status))
        }
    }

    /// Pixel statistics, not PNG bytes. Comparing two PNG `Data` of the same
    /// view failed in 5 of the 8 recorded isolated runs of 2026-09-14 and in
    /// the full suite, always on a comparison involving the process's first
    /// `ImageRenderer` draw; `PixelDiff.swift` carries the measurement.
    /// `pixelDiff` redraws both images into one canonical 8-bit sRGB buffer
    /// and compares numbers. At 96 × 96 the t = 0.2 and t = 1.3 frames differ
    /// by mean 5.3 levels with 11 % of pixels past 8 levels, while the same
    /// instant redrawn differs by nothing at all.
    ///
    /// Not covered: the live TimelineView branch and `preset.speed` — every
    /// render here takes the `orbFrozenTime` path, which is documented
    /// (ThinkingOrb.swift:77) as raw engine time, NOT scaled by speed.
    @Test func nativeRibbonFramesMoveAndStaticPreviewsFreeze() throws {
        func render(_ time: Double?, frozen: Bool = false) throws -> CGImage {
            let view = RecognitionOrb(lightInk: true, frozenTime: time)
                .environment(\.staticRender, frozen)
                .padding(8).background(.black)
            let image = try renderedImage(view, scale: 2)
            try #require(image.width == 96 && image.height == 96,
                         "96 px = (32 pt orb + 8 pt padding × 2) × scale 2 — got \(image.width)×\(image.height)")
            return image
        }
        // Warm-up. The old test's failures clustered on the process's first
        // ImageRenderer draw; three diagnostic runs did not reproduce the
        // difference, so the layer is still unknown and these draws stay — one
        // per argument that later feeds an equality assertion. The
        // repeated-render check below is what turns a recurrence into a
        // diagnosable failure instead of a silent one.
        _ = try render(0.2)
        _ = try render(nil, frozen: true)
        _ = try render(0.6)

        // The ribbon's geometry must be a function of t — the same canvas at
        // two instants must differ.
        let moving = try pixelDiff(render(0.2), render(1.3))
        #expect(moving.mean > 1.0, "the ribbon geometry must depend on t — \(moving)")
        #expect(moving.movedFraction > 0.02, "the ribbon geometry must depend on t — \(moving)")

        // The same frozen instant must redraw the same frame.
        let repeated = try pixelDiff(render(0.2), render(0.2))
        #expect(repeated.mean < 0.5, "t = 0.2 must redraw identically — \(repeated)")
        #expect(repeated.maxChannel <= 8, "t = 0.2 must redraw identically — \(repeated)")

        // The staticRender preview must not move between renders…
        let frozen = try pixelDiff(render(nil, frozen: true), render(nil, frozen: true))
        #expect(frozen.mean < 0.5, "the static preview must not move — \(frozen)")
        #expect(frozen.maxChannel <= 8, "the static preview must not move — \(frozen)")

        // …and it must be the instant RecognitionOrb.swift:14 pins it to, t = 0.6.
        let pinned = try pixelDiff(render(nil, frozen: true), render(0.6))
        #expect(pinned.mean < 0.5, "the static preview must be the t = 0.6 frame — \(pinned)")
        #expect(pinned.maxChannel <= 8, "the static preview must be the t = 0.6 frame — \(pinned)")
    }
}
