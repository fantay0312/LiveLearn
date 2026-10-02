import CoreGraphics
import Foundation
import SwiftUI

// Shared image comparison for the tests in this target.
//
// `RecognitionOrbTests` compared two PNG `Data` of the same view and failed
// in 5 of the 8 recorded isolated runs of 2026-09-14, and in the full suite
// (`doc/项目实现文档.md` §6 records ~85 % there) — always on a comparison
// involving the process's first `ImageRenderer` draw. Measured here: the
// difference did not reproduce in three runs, so the layer it lives in is
// still unknown. See `pixelDiff` for what replaced the byte comparison.

enum PixelDiffError: Error {
    /// `ImageRenderer` produced no image.
    case renderFailed
    /// A canonical sRGB context could not be made for the image.
    case undecodable
    /// The two images are not the same size, so a per-pixel diff is meaningless.
    case mismatchedSize(width: Int, height: Int, otherWidth: Int, otherHeight: Int)
    /// An image carries a pixel with alpha < 255. `pixelDiff` compares R/G/B
    /// only, so it would silently call two images identical when their whole
    /// difference lives in the alpha channel.
    case notOpaque
}

/// How far apart two renders of the same size are.
struct RenderDiff: CustomStringConvertible {
    /// Mean absolute difference per colour sample in 8-bit levels (0…255),
    /// averaged over R, G and B of every pixel. Alpha is excluded, and
    /// `pixelDiff` enforces that both images are opaque so nothing hides there.
    let mean: Double
    /// Largest absolute difference on any single R/G/B sample (0…255).
    let maxChannel: Int
    /// Fraction of all pixels (0…1) whose largest R/G/B difference is > 8 levels.
    let movedFraction: Double

    /// Calibrated on RecognitionOrb at 96 × 96 (`spec-orb-test.md` §2): two
    /// frames 1.1 s apart measure mean 5.3 with 10.8 % of pixels moved, while
    /// the same instant redrawn measures 0 and 0. New image tests should use
    /// these two predicates rather than invent fresh numbers.
    ///
    /// The moving side keeps ~5× headroom over the measurement deliberately,
    /// not by typo: three independent measurements (4.61 simulated, 4.83 and
    /// 5.31 on hardware) spread by only ~10 %, so the margin is there to
    /// tolerate a legitimately retuned ribbon, not machine noise. The frozen
    /// side is tight on purpose — a 2 ms clock drift already reaches 9 levels.
    var isUnchanged: Bool { mean < 0.5 && maxChannel <= 8 }

    /// See `isUnchanged` for the calibration these thresholds come from.
    var hasMoved: Bool { mean > 1.0 && movedFraction > 0.02 }

    var description: String {
        String(format: "mean %.3f levels, max %ld levels, %.2f%% of pixels moved by > 8 levels",
               mean, maxChannel, movedFraction * 100)
    }
}

/// Render a view offscreen at `scale`, or throw. `scale` is explicit because
/// the raster size decides `movedFraction`: the same view at 1× and at 2× has
/// a different share of anti-aliased edge pixels, so a test ported between
/// scales has to be recalibrated rather than merely recompiled.
@MainActor
func renderedImage(_ view: some View, scale: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { throw PixelDiffError.renderFailed }
    return image
}

/// Redraw `image` into tightly packed 8-bit sRGB RGBA and return the raw
/// samples: 4 bytes per pixel, row-major, `bytesPerRow == width * 4`, so pixel
/// (x, y) starts at `(y * width + x) * 4`. **Alpha is premultiplied**
/// (`.premultipliedLast`), so a semi-transparent pixel's R/G/B are already
/// scaled by its alpha — divide by `a / 255` before comparing against a
/// straight colour such as `NSColor.redComponent`.
///
/// Non-private so other image tests can fetch a whole buffer once instead of
/// calling `NSBitmapImageRep.colorAt(x:y:)` per pixel.
func canonicalSamples(_ image: CGImage) throws -> [UInt8] {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw PixelDiffError.undecodable
    }
    var samples = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = samples.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        return true
    }
    guard drawn else { throw PixelDiffError.undecodable }
    return samples
}

private func isFullyOpaque(_ samples: [UInt8]) -> Bool {
    stride(from: 3, to: samples.count, by: 4).allSatisfy { samples[$0] == 255 }
}

/// Compare two renders of the same size as pixel statistics rather than as
/// encoded bytes. Both images are redrawn through `canonicalSamples`, so a
/// difference in the source bitmap's layout or colour profile — or in what the
/// PNG encoder made of it — cannot masquerade as a difference in what was
/// actually drawn. That is why `RecognitionOrbTests` measures numbers against
/// thresholds instead of comparing two PNG `Data` for equality.
///
/// Precondition: both images must be fully opaque, for instance by rendering
/// the view over `.background(.black)`. `pixelDiff` throws
/// `PixelDiffError.notOpaque` otherwise, because it does not compare alpha and
/// would report two images differing only in alpha as identical.
///
/// Use `RenderDiff.isUnchanged` / `RenderDiff.hasMoved` for calibrated
/// thresholds rather than fresh literals.
func pixelDiff(_ lhs: CGImage, _ rhs: CGImage) throws -> RenderDiff {
    guard lhs.width == rhs.width, lhs.height == rhs.height else {
        throw PixelDiffError.mismatchedSize(width: lhs.width, height: lhs.height,
                                            otherWidth: rhs.width, otherHeight: rhs.height)
    }
    let left = try canonicalSamples(lhs)
    let right = try canonicalSamples(rhs)
    guard isFullyOpaque(left), isFullyOpaque(right) else { throw PixelDiffError.notOpaque }
    let pixels = lhs.width * lhs.height
    var total = 0
    var worst = 0
    var moved = 0
    for p in 0..<pixels {
        var pixelWorst = 0
        for c in 0..<3 {
            let d = abs(Int(left[p * 4 + c]) - Int(right[p * 4 + c]))
            total += d
            if d > pixelWorst { pixelWorst = d }
        }
        if pixelWorst > worst { worst = pixelWorst }
        if pixelWorst > 8 { moved += 1 }
    }
    return RenderDiff(mean: Double(total) / Double(pixels * 3),
                      maxChannel: worst,
                      movedFraction: Double(moved) / Double(pixels))
}
