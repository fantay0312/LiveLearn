import SwiftUI
import CloudEngine

/// A term's type, drawn the way the star map draws the term itself (round 12): a hot word is a
/// single point of light, a word with a fixed translation a **binary star** — two close points,
/// the word and its translation, sharing one halo. Shape as well as hue carries the type, so the
/// list gutter, the rail's legend (before the 热词 / 术语 counts) and the import preview read the
/// same in grey and with Differentiate Without Color.
///
/// - `lit` is "chosen": the point lights into the `StarMark` in the class hue (a selected list
///   row); a binary keeps its companion beside the star.
/// - Dark: ice `starBlue` / gold `ochre` over one faint halo, so the mark reads as light. Light
///   (paper): crisp points in forest / ochre ink, no halo. Increase Contrast: no halo, full ink.
/// - Static (a `Canvas` with no clock) in a fixed 12 × 12 slot, hidden from VoiceOver: a list row
///   speaks its type as its accessibility value, the rail row beside the legend glyph is named
///   热词 / 术语, and an import preview row reads its translation when it has one.
struct VocabularyKindMark: View {
    let kind: VocabularyKind
    var lit = false
    @Environment(\.theme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    static let side: CGFloat = 12

    var body: some View {
        let tint = Self.tint(kind, theme: theme)
        ZStack {
            if lit { StarMark(tint: tint) }
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let increased = contrast == .increased
                let paper = !theme.isDark
                // One halo for the pair (the lit star brings its own).
                if !lit && !increased && !paper {
                    let r: CGFloat = kind == .hotWord ? 3.5 : 4.5
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                                 with: .radialGradient(Gradient(colors: [tint.opacity(0.28), .clear]),
                                                       center: centre, startRadius: 0, endRadius: r))
                }
                for point in Self.points(kind, lit: lit, centre: centre, paper: paper) {
                    let d = point.diameter
                    context.fill(Path(ellipseIn: CGRect(x: point.at.x - d / 2, y: point.at.y - d / 2, width: d, height: d)),
                                 with: .color(tint.opacity(increased ? 1 : point.alpha)))
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The class hue: ice for hot words, gold for fixed translations (forest / ochre on paper).
    static func tint(_ kind: VocabularyKind, theme: LLTheme) -> Color {
        kind == .hotWord ? theme.starBlue : theme.ochre
    }

    struct Point: Equatable {
        let at: CGPoint
        let diameter: CGFloat
        let alpha: Double
    }

    /// The points the mark draws in a slot centred on `centre`. Unlit: one point, or the binary
    /// pair straddling the centre along the companion axis (up and to the right, as on the map at
    /// rest). Lit: the star is the primary, so only a binary's companion is drawn, one separation
    /// from the star's centre.
    static func points(_ kind: VocabularyKind, lit: Bool, centre: CGPoint, paper: Bool) -> [Point] {
        let core: CGFloat = paper ? 2.2 : 2.0
        guard kind == .glossary else {
            return lit ? [] : [Point(at: centre, diameter: core, alpha: 0.9)]
        }
        let angle = LexiconConstellation.markCompanionAngle
        let step = CGPoint(x: cos(angle) * LexiconConstellation.binarySeparation,
                           y: sin(angle) * LexiconConstellation.binarySeparation)
        let reach: CGFloat = lit ? 1 : 0.5
        // Beside the lit star the companion scales from the star's own core, so it stays the
        // lesser of the two.
        let companionCore = lit ? SettingsStarPoint.core(paper: paper) : core
        let companion = Point(at: CGPoint(x: centre.x + step.x * reach, y: centre.y + step.y * reach),
                              diameter: companionCore * LexiconConstellation.companionScale, alpha: 0.8)
        if lit { return [companion] }
        return [Point(at: CGPoint(x: centre.x - step.x * 0.5, y: centre.y - step.y * 0.5), diameter: core, alpha: 0.9),
                companion]
    }
}
