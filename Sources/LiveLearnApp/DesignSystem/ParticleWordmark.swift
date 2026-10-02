import AppKit
import CoreText
import SwiftUI

/// Fine starlight follows the actual glyphs, so the brand remains a readable word.
///
/// Live in the window header it draws with Metal (`WordmarkScene` in a `SpriteLayerView`, its
/// own 15 Hz display link, no SwiftUI render pass); a static render, a frozen time, Reduce
/// Motion, a machine without a GPU or a caller on `.canvas` gets the Canvas, which stays the
/// reference.
///
/// On paper the word is engraved rather than lit: neutral ink grains (the forest accent is kept
/// for what is lit now), no soft halos, which on cream read as a blur, and the grains' shimmer
/// kept within 0.82…0.98 alpha — at the lit word's 0.1…0.9 the stipple printed as a faded grey
/// and lost the word's presence. The engraved Canvas composites grain by grain, as the sprites
/// do: filled as one path per bin, two grains sharing a pixel cover it once, while the sprites
/// cover it twice at partial coverage (lighter) — at these alphas that difference alone put the
/// pair past the parity gate. The lit word keeps its five paths (its recorded deviation, W1,
/// stays inside the gate at its alphas).
struct ParticleWordmark: View {
    /// The grain tint for a theme, shared with `WordmarkScene`: pearl on the dark sky, ink on paper.
    static func tint(_ theme: LLTheme) -> Color { theme.isDark ? Color(hex: 0xE3F0F6) : theme.ink }

    /// A grain bin's alpha, shared with `WordmarkScene`: the lit word spreads its five bins over
    /// 0.1…0.9; the engraved one (paper) keeps the same five steps inside 0.82…0.98.
    nonisolated static func alpha(bin: Int, engraved: Bool) -> Double {
        let step = (Double(bin) + 0.5) / 5
        return engraved ? 0.80 + 0.20 * step : step
    }

    var frozenTime: Double? = nil
    var renderer: AmbientRenderer = .canvas
    @Environment(\.theme) private var theme
    @Environment(\.staticRender) private var staticRender
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Grain {
        let point: CGPoint
        let radius: Double
        /// sin / cos of the grain's phase: every per-frame term is `sin(ωt + φ)`, so it is
        /// evaluated as `sin ωt · cos φ + cos ωt · sin φ` with three `sin`/`cos` per frame in all.
        let sinPhase: Double
        let cosPhase: Double
    }

    /// The glyph-sampled grains in the 98 × 36 pt frame, built once per process (and off the
    /// main actor: `WordmarkScene` encodes them, and the tests read them).
    nonisolated static let grains: [Grain] = {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "LiveLearn", attributes: [.font: font, .kern: 0.15]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                if let glyph = CTFontCreatePathForGlyph(font, glyphs[index], nil) {
                    path.addPath(glyph, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
                }
            }
        }
        let bounds = path.boundingBoxOfPath
        var points: [Grain] = []
        var state: UInt64 = 0xAA17945
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
        for y in stride(from: bounds.minY, through: bounds.maxY, by: 0.58) {
            for x in stride(from: bounds.minX, through: bounds.maxX, by: 0.58) {
                let p = CGPoint(x: x + (random() - 0.5) * 0.24, y: y + (random() - 0.5) * 0.24)
                guard path.contains(p) else { continue }
                let radius = 0.23 + random() * 0.14
                let phase = random() * .pi * 2
                points.append(Grain(point: CGPoint(x: p.x - bounds.minX + 5, y: bounds.maxY - p.y + (36 - bounds.height) / 2),
                                    radius: radius, sinPhase: sin(phase), cosPhase: cos(phase)))
            }
        }
        return points
    }()

    var body: some View {
        Group {
        if let metal = AmbientRendering.metalRenderer(for: renderer, layer: .wordmark, staticRender: staticRender, frozenTime: frozenTime, reduceMotion: reduceMotion) {
            SpriteLayerView(renderer: metal, scene: WordmarkScene(tint: AmbientRendering.components(Self.tint(theme)), engraved: !theme.isDark))
        } else {
        // The grains move by a tenth of a point and the light breathes slowly: 15 frames a
        // second is indistinguishable from 30 here, and 15 is every other frame of the scene's
        // 30 Hz clock, so the wordmark never asks for a render pass the other layers do not.
        LuminousMotion(active: true, frozenTime: frozenTime, rate: 15) { time in
            Canvas { context, _ in
                let color = Self.tint(theme)
                let engraved = !theme.isDark
                let halo = context.resolve(ParticleSprites.halo(0xE3F0F6))
                let sX = sin(time * 0.65), cX = cos(time * 0.65)
                let sY = sin(time * 0.53), cY = cos(time * 0.53)
                let sL = sin(time * 0.75), cL = cos(time * 0.75)
                var bins = Array(repeating: [CGRect](), count: 5)
                for (index, grain) in Self.grains.enumerated() {
                    // sin(ωt + φ) = sin ωt cos φ + cos ωt sin φ ; cos(ωt + φ) = cos ωt cos φ − sin ωt sin φ
                    let x = grain.point.x + (sX * grain.cosPhase + cX * grain.sinPhase) * 0.12
                    let y = grain.point.y + (cY * grain.cosPhase - sY * grain.sinPhase) * 0.10
                    let light = 0.68 + (sL * grain.cosPhase + cL * grain.sinPhase) * 0.22
                    bins[min(4, max(0, Int(light * 5)))].append(CGRect(x: x - grain.radius, y: y - grain.radius,
                        width: grain.radius * 2, height: grain.radius * 2))
                    if !engraved && index % 157 == 0 {
                        var glow = context
                        glow.opacity = light * 0.22
                        glow.draw(halo, in: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2))
                    }
                }
                // Faint to bright, in grain order inside a bin: the sprites' order.
                for index in bins.indices where !bins[index].isEmpty {
                    let shading = GraphicsContext.Shading.color(color.opacity(Self.alpha(bin: index, engraved: engraved)))
                    if engraved {
                        for rect in bins[index] { context.fill(Path(rect), with: shading) }
                    } else {
                        var path = Path()
                        path.addRects(bins[index])
                        context.fill(path, with: shading)
                    }
                }
            }
        }
        }
        }
        .frame(width: 98, height: 36)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore).accessibilityLabel("LiveLearn").accessibilityAddTraits(.isImage)
        .help("LiveLearn")
    }
}
