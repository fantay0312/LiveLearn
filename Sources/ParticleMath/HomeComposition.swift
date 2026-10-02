import CoreGraphics
import Foundation

/// Home as one instrument on one vertical axis: the stardust core, the action capsule, one row
/// (the modes, or the running status), the configuration sentence — in that order, on a fixed
/// rhythm, centred in the band between the window header and the dock.
///
/// It is the single source of that composition for everything that depends on it: the page
/// lays its views out with it, and the particle layers that must keep the operating area dark —
/// the dust's two fades, the stars' quiet box, the glint keep-out and the pointer's protected
/// zone — read the same numbers, so moving the core or the controls moves all of them together,
/// on the Canvas path and the Metal path alike.
///
/// The composition is fixed per window size and deliberately blind to session state: the core
/// and the capsule never move when a session starts or a mode changes. The reference unit is the
/// idle page with one route; whatever else a state shows (a second route, the cloud note, a
/// blocker) grows downward into the air below it.
public struct HomeComposition: Equatable, Sendable {
    /// The window chrome around the page, as `RootView` lays it out: the 48 pt header and the dock
    /// (a 40 pt row with 8 pt above and 16 pt below it).
    public static let headerHeight = 48.0
    public static let dockHeight = 64.0

    /// How far the core's grains reach from its centre at rest, as a fraction of the stage side:
    /// the last scattered grains of the feathered rim (measured 0.336 in a still at 360 pt; the
    /// dense body ends near 0.29, so the rim feathers some 15 pt toward the capsule). Breath and
    /// pulses reach past it for a moment; the rhythm is measured here.
    public static let coreReach = 0.33
    /// The stage side's range (DESIGN: the core renders at 210–360 pt).
    public static let coreRange = 210.0...360.0

    /// The rhythm below the core. `coreToCapsule` is optical (from the grains, not the stage);
    /// the row gaps are frame gaps that land on 24 pt of visible air, because the row's orbit
    /// sits 7.5 pt inside its 44 pt frame and the sentence's glyphs 7.5 pt inside theirs.
    public static let coreToCapsule = 44.0
    public static let capsuleHeight = 48.0
    public static let capsuleToRow = 16.0
    public static let rowHeight = 44.0
    public static let rowToConfiguration = 8.0
    public static let configurationHeight = 30.0
    /// Everything of the reference unit that is not core.
    public static let controlsHeight = coreToCapsule + capsuleHeight + capsuleToRow + rowHeight
        + rowToConfiguration + configurationHeight

    /// Air the core leaves around the unit before it gives up size…
    public static let reservedAir = 118.0
    /// …of which this much always stays below the unit, whatever centring would say: a converse
    /// route (+34 pt), a failure or blocker (its title line and a one-line detail) and the cloud
    /// note after it all fit above the dock at the minimum window (the user's choice, 2026-09-28:
    /// the minimum core pays for it, 272.7 → 233.7 pt; the default window keeps its 360 pt core
    /// and its centring).
    public static let growthAir = 104.0
    /// The sentence's glyphs end this far above its 30 pt line: the unit is centred on what is
    /// seen — the grains' reach above, the glyphs below — not on the frames.
    public static let configurationGlyphInset = 7.5
    /// The visible unit sits this much above the band's centre: the optical centre is slightly
    /// high.
    public static let opticalLift = 4.0

    /// Half the width of the widest control: the 184 pt capsule with the 80 pt stop hanging at
    /// 12 pt to its right (the rail keeps the capsule centred, so it reaches as far left).
    /// ParticleMath cannot see the controls; `Round12HomeTests` ties this to their widths.
    public static let controlHalfWidth = 184.0
    /// Glint-magnitude stars and bright dust keep at least this far from text and controls…
    public static let keepOut = 28.0
    /// …and are fully suppressed within this distance; between the two they fade in smoothly.
    public static let keepOutCore = 12.0

    public let width: Double
    public let pageHeight: Double
    /// The core's stage side.
    public let coreDiameter: Double
    /// Page space (y from the top of the page area).
    public let coreCenterY: Double
    public let capsuleTop: Double

    public init(pageWidth: Double, pageHeight: Double) {
        width = max(0, pageWidth)
        self.pageHeight = max(0, pageHeight)
        // The core leaves the unit its reserved air, and never grows so far that its stage's
        // clear top margin (0.5 − reach of the side) would push the unit into the growth air.
        let fitted = min((self.pageHeight - Self.controlsHeight - Self.reservedAir) / (2 * Self.coreReach),
                         (self.pageHeight - Self.controlsHeight - Self.growthAir) / (0.5 + Self.coreReach))
        coreDiameter = min(Self.coreRange.upperBound, max(Self.coreRange.lowerBound, fitted))
        let reach = coreDiameter * Self.coreReach
        let unit = 2 * reach + Self.controlsHeight
        let visible = unit - Self.configurationGlyphInset
        // Centred by what is seen, lifted a little; never so low that the rows a state can add
        // lose their room above the dock, and never above the page: the stage's clear top
        // margin stays inside it (a breath or a pulse reaches into that margin), even where the
        // core has just reached full size.
        let centred = (self.pageHeight - visible) / 2 - Self.opticalLift
        let top = max(coreDiameter / 2 - reach, min(centred, self.pageHeight - unit - Self.growthAir))
        coreCenterY = top + reach
        capsuleTop = coreCenterY + reach + Self.coreToCapsule
    }

    public init(windowWidth: Double, windowHeight: Double) {
        self.init(pageWidth: windowWidth, pageHeight: windowHeight - Self.headerHeight - Self.dockHeight)
    }

    // MARK: Page space

    /// The visible reach of the core's grains in points.
    public var coreRadius: Double { coreDiameter * Self.coreReach }
    /// The stage's top edge; the stage is square and centred on the core.
    public var stageTop: Double { coreCenterY - coreDiameter / 2 }
    /// From the stage's bottom edge to the capsule's top: negative where the stage's clear lower
    /// margin overlaps the capsule's slot (the stage draws nothing there and takes no input).
    public var stageToCapsule: Double { capsuleTop - (coreCenterY + coreDiameter / 2) }
    public var rowTop: Double { capsuleTop + Self.capsuleHeight + Self.capsuleToRow }
    public var configurationTop: Double { rowTop + Self.rowHeight + Self.rowToConfiguration }
    /// The reference unit's last line.
    public var unitBottom: Double { configurationTop + Self.configurationHeight }

    // MARK: Window space (the sky and the pointer surface cover the whole window)

    public var windowHeight: Double { pageHeight + Self.headerHeight + Self.dockHeight }
    public var axisX: Double { width / 2 }
    public var windowCoreCenter: CGPoint { CGPoint(x: axisX, y: coreCenterY + Self.headerHeight) }
    public var windowCapsuleTop: Double { capsuleTop + Self.headerHeight }
    public var windowUnitBottom: Double { unitBottom + Self.headerHeight }
    /// The top of the dock row: below it only navigation lives.
    public var dockTop: Double { windowHeight - Self.dockHeight }

    /// How clear a window point is of every text and control Home draws — the header, the dock and
    /// the control column from the capsule down: 0 within `keepOutCore` of one, 1 beyond
    /// `keepOut`, smooth between. The sky's glint-magnitude stars and brighter dust scale by it,
    /// so nothing bright sits under a word as a false badge.
    public func clearance(x: Double, y: Double) -> Double {
        // Signed distances to the three regions, negative inside: the header band, the dock band
        // and the column (which runs from the capsule's top edge down into the dock).
        let header = y - Self.headerHeight
        let dock = dockTop - y
        let dx = abs(x - axisX) - Self.controlHalfWidth, dy = windowCapsuleTop - y
        let column = hypot(max(0, dx), max(0, dy)) + min(0, max(dx, dy))
        let distance = min(header, dock, column)
        let t = min(1, max(0, (distance - Self.keepOutCore) / (Self.keepOut - Self.keepOutCore)))
        return t * t * (3 - 2 * t)
    }
}
