import SwiftUI

/// Every separator in the app (round 12): a 0.5 pt hairline whose ends fade instead of stopping
/// — `SettingsRule`'s recipe (the theme `hairline` at 55 %, 1 px on Retina) made available to
/// every surface. A rule that simply stops reads as broken; one that fades reads as ending.
///
/// - `.trailing`: solid from where the text starts, fading at the far end — the rule under a
///   left-aligned column (rows, groups, popover sections, menu dividers).
/// - `.both`: fading at both ends — a free-standing divider such as a vertical column or pane
///   rule, which belongs to neither side.
///
/// `fade` is the length of each fade in points; `nil` fades over the last tenth of the length,
/// which is `SettingsRule` exactly. A long vertical rule should name its fade (24–64 pt) so it
/// does not wash out a tenth of the window. The rule is greedy along its axis and 0.5 pt
/// across it; callers inset it to their text column with padding.
struct FadingRule: View {
    enum Ends { case trailing, both }

    var axis: Axis = .horizontal
    var ends: Ends = .trailing
    var fade: CGFloat? = nil
    /// Share of the theme `hairline`; 0.55 is the settings rule.
    var strength: Double = 0.55
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let color = theme.hairline.opacity(strength)
            LinearGradient(stops: Self.stops(length: length, ends: ends, fade: fade).map {
                .init(color: $0.opaque ? color : .clear, location: $0.location)
            }, startPoint: axis == .horizontal ? .leading : .top, endPoint: axis == .horizontal ? .trailing : .bottom)
        }
        .frame(width: axis == .vertical ? 0.5 : nil, height: axis == .horizontal ? 0.5 : nil)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Gradient stops along the rule, 0…1. A named fade is clamped to half the length, so a
    /// short rule with `.both` still peaks in its middle instead of inverting.
    static func stops(length: CGFloat, ends: Ends, fade: CGFloat?) -> [(location: CGFloat, opaque: Bool)] {
        let share = fade.map { length > 0 ? min(0.5, $0 / length) : 0.5 } ?? 0.10
        switch ends {
        case .trailing:
            return [(0, true), (1 - share, true), (1, false)]
        case .both:
            return [(0, false), (share, true), (1 - share, true), (1, false)]
        }
    }
}
