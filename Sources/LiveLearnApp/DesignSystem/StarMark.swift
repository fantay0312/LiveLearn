import SwiftUI

/// "What you chose" (round 12, the star-chart grammar): one stamped point of light beside or
/// under the chosen thing, used by every host surface that marks a choice — paper-menu rows,
/// rails, word choices, changed draft values. Orbits mean *where you are*, the 2 pt `NowMark`
/// means *live*; this means *chosen*, and the three are never mixed.
///
/// The host face of the helper-shared `SettingsStarPoint` (UnifiedSettingsNavigation.swift),
/// which holds the one recipe — core, rays, halo, the paper rule, Increase Contrast, the stamp's
/// drop under a word — so a star in a menu, in a rail and in Settings is one substance and a
/// change to it is made once. This view reads dark / paper from `LLTheme` and adds the one thing
/// the helper has no use for: a class hue (the vocabulary's ice and gold), painted through the
/// shared star's own coverage instead of by a second copy of the recipe. Under Increase Contrast
/// the hue is dropped and the point is plain `ink`, as every star is there.
///
/// Stamped, never faded; placed in a fixed slot or at a fixed offset, so layout never moves.
/// Static (a `Canvas` with no clock), so it also draws in offscreen renders.
struct StarMark: View {
    enum Placement {
        /// Centred in its own 8 pt slot (a menu's mark column, a rail's gutter).
        case slot
        /// Under a word: attach with `.overlay(alignment: .bottom)` to the `Text` itself, before
        /// any padding or frame, and the point lands ≈ 6.75 pt under the ink of a 13 pt CJK word
        /// (the `SettingsStarPoint` stamp — see there for why the offset is measured from the
        /// text box).
        case under
    }

    var placement: Placement = .slot
    /// A hue for the point instead of the theme's star (the vocabulary rail's class colours).
    var tint: Color? = nil
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let star = SettingsStarPoint(dark: theme.isDark, stamped: placement == .under)
        if let tint, contrast != .increased {
            // The hue field reaches 12 pt past the 8 pt slot on every side — beyond a stamped
            // point's drop — so the mask never clips the star it shapes.
            tint.padding(-12)
                .frame(width: 8, height: 8)
                .mask { star }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            star
        }
    }
}

extension View {
    /// Stamps a `StarMark` under this word when `marked` (a word choice: 星图 / 列表, a segment,
    /// a word toggle that is on). Attach it to the `Text` before padding or a frame. The word
    /// itself must also turn `ink` when chosen — the point is never the only sign — and the
    /// chosen control keeps its `.isSelected` (or on / off) trait.
    func starMarked(_ marked: Bool, tint: Color? = nil) -> some View {
        overlay(alignment: .bottom) {
            if marked { StarMark(placement: .under, tint: tint) }
        }
    }
}
