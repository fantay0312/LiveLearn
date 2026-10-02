import CoreGraphics
import Foundation

/// The drifting point sources of `StellarAtmosphere`: each star's anchor, phase, depth and
/// drift rates are fixed per index and tabulated once, so a frame does no string hashing.
public enum StarFieldGeometry {
    public static let maxCount = 290

    public struct Star: Sendable {
        /// Anchor in unit space; for a formation star the formation index and its progress.
        let anchorX: Double
        let anchorY: Double
        let formation: Int
        let progress: Double
        let phase: Double
        let depth: Double
        public let bright: Bool
        public let medium: Bool
        /// Every ninth star is ice-tinted; the rest are pearl.
        public let ice: Bool
    }

    public static let stars: [Star] = (0..<maxCount).map { index in
        let onFormation = index % 5 == 0
        let anchor = onFormation ? CGPoint.zero : CGPoint(x: StableHash.fraction("sky-x-\(index)"), y: StableHash.fraction("sky-y-\(index)"))
        return Star(anchorX: anchor.x, anchorY: anchor.y,
                    formation: onFormation ? (index / 5) % 4 : -1,
                    progress: onFormation ? StableHash.fraction("formation-star-\(index)") : 0,
                    phase: Double(index) * 2.39996,
                    depth: Double((index * 17 + 5) % 97) / 97,
                    bright: index % 29 == 0, medium: index % 5 == 0, ice: index % 9 == 0)
    }

    /// Where star `index` is at `time`, in a `size` canvas.
    public static func position(index: Int, time: Double, size: CGSize) -> CGPoint {
        let star = stars[index % maxCount]
        let anchor = star.formation >= 0
            ? NebulaFieldGeometry.formation(star.formation, progress: star.progress, time: time)
            : CGPoint(x: star.anchorX, y: star.anchorY)
        let depth = star.depth, phase = star.phase
        return CGPoint(x: (anchor.x + sin(time * (0.23 + depth * 0.13) + phase) * (0.025 + depth * 0.020)) * size.width,
                       y: (anchor.y + cos(time * (0.19 + depth * 0.11) + phase * 1.3) * (0.023 + depth * 0.018)) * size.height)
    }

    /// How one star is drawn: its disc, and for a bright star in open sky its 12 pt halo and the
    /// two 0.5 pt bars of its glint cross.
    public struct Look: Sendable {
        public let diameter: Double
        public let opacity: Double
        /// Peak alphas of the halo and of the glint bars; nil when the star has neither.
        public let glint: (halo: Double, cross: Double)?
    }

    /// The one rule both renderers draw a star by (`StellarAtmosphere`'s Canvas and
    /// `encodePoints`), so the two cannot drift apart. On immersive Home the stars dim to 0.06
    /// inside the quiet box around the operating area (the core's centre down to the last
    /// control line, ± 235 pt, feathered over 110 / 90 pt); elsewhere every star sits at 0.48.
    /// A bright star keeps its glint only where `composition` says the sky is clear of text and
    /// controls, and shrinks to a medium star's disc as it nears them — a glint under a word
    /// reads as a badge. `composition` is nil off immersive Home, where no star glints; there
    /// `keepOut` holds the page's rails and top line, and every star fades out near them.
    public static func look(_ star: Star, index: Int, at position: CGPoint, time: Double,
                            composition: HomeComposition?, keepOut: SkyKeepOut = SkyKeepOut()) -> Look {
        let x = Double(position.x), y = Double(position.y)
        let quiet: Double
        var clearance = 1.0
        if let composition {
            let top = Double(composition.windowCoreCenter.y), bottom = composition.windowUnitBottom
            let dx = max(0, abs(x - composition.axisX) - 235) / 110
            let dy = max(0, abs(y - (top + bottom) / 2) - (bottom - top) / 2) / 90
            quiet = 0.06 + min(1, hypot(dx, dy)) * 0.94
            if star.bright { clearance = composition.clearance(x: x, y: y) }
        } else {
            // Every magnitude, not only the bright: beside a rail's legend point any grain reads
            // as the binary glyph, and under the search line as a badge.
            clearance = keepOut.clearance(x: x, y: y)
            quiet = 0.48 * clearance
        }
        let shimmer = 0.75 + 0.25 * sin(time * 0.85 + Double(index) * 1.7)
        let diameter = star.bright ? 1.15 + 0.75 * clearance : (star.medium ? 1.15 : 0.7)
        let peak = star.bright ? 0.46 + 0.39 * clearance : (star.medium ? 0.46 : 0.23)
        let glints = star.bright && quiet > 0.6 && clearance > 0
        return Look(diameter: diameter, opacity: peak * quiet * shimmer,
                    glint: glints ? (halo: 0.14 * quiet * clearance, cross: 0.20 * quiet * shimmer * clearance) : nil)
    }
}

/// Where the sky keeps its stars off a page's words when no `HomeComposition` governs it: the
/// records and vocabulary rails and the vocabulary page's top line, in window points
/// (`RootView`). Home's rule, applied to rects: clearance 0 within `HomeComposition.keepOutCore`
/// of one, 1 beyond `HomeComposition.keepOut`, smooth between.
public struct SkyKeepOut: Equatable, Sendable {
    public var rects: [CGRect]

    public init(_ rects: [CGRect] = []) {
        self.rects = rects
    }

    public func clearance(x: Double, y: Double) -> Double {
        guard !rects.isEmpty else { return 1 }
        var distance = Double.infinity
        for rect in rects {
            // Signed distance to the rect, negative inside.
            let dx = max(Double(rect.minX) - x, x - Double(rect.maxX))
            let dy = max(Double(rect.minY) - y, y - Double(rect.maxY))
            distance = min(distance, hypot(max(0, dx), max(0, dy)) + min(0, max(dx, dy)))
        }
        let t = min(1, max(0, (distance - HomeComposition.keepOutCore) / (HomeComposition.keepOut - HomeComposition.keepOutCore)))
        return t * t * (3 - 2 * t)
    }
}
