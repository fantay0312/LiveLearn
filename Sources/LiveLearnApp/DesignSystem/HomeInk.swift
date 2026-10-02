import SwiftUI

/// Home's quiet inks. Configuration values are quieter than the action (ink2, chevrons ink3)
/// and brighten when touched; Increase Contrast lifts each by one step — values a third of the
/// way from ink2 to ink, chevrons to ink2 — because `LLTheme.increasedContrast()` lifts only
/// fills and rules and would leave these as they were. Full ink stays the action's and the
/// chosen word's alone, so the hierarchy holds under Increase Contrast too.
struct HomeInk {
    /// Resting configuration values, the status word, a resting navigation or mode label.
    let value: Color
    /// Chevrons, separators, the clock, an off toggle.
    let quiet: Color
    /// Full ink: a value touched or open, the chosen word.
    let strong: Color

    init(_ theme: LLTheme) {
        let raised = theme.raisesContrast
        value = raised ? theme.ink2.mix(with: theme.ink, by: 1.0 / 3) : theme.ink2
        quiet = raised ? theme.ink2 : theme.ink3
        strong = theme.ink
    }
}
