import SwiftUI

/// Design language §4. System fonts only; CJK falls back automatically. Digits are monospaced.
enum LLFont {
    static let label = Font.system(size: 11, weight: .regular)
    static let labelStrong = Font.system(size: 11, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyStrong = Font.system(size: 13, weight: .medium)
    static let heading = Font.system(size: 15, weight: .medium)
    /// A configuration value the user reads and changes (the source and direction in the
    /// source popover): the heading's size at regular weight, so it is larger than its 11 pt
    /// label without outranking the channel name above it.
    static let value = Font.system(size: 15, weight: .regular)
    /// The title of a sheet or popover (音源与语言, 翻译方向, 音源检查): one step above the value,
    /// medium — never bold. At regular weight the larger, thinner title carried no more weight
    /// than the 15/500 channel names under it, so the popover had no leader.
    static let title = Font.system(size: 17, weight: .medium)
    /// The one opening line of an empty window: larger and lighter than a form heading, so it
    /// reads like the first line on a page rather than a control label.
    static let display = Font.system(size: 24, weight: .regular)
    static let timestamp = Font.system(size: 11, weight: .regular).monospacedDigit()

    static func transcriptTarget(serif: Bool) -> Font {
        serif ? Font.system(size: 18, weight: .regular, design: .serif) : Font.system(size: 17, weight: .regular)
    }
    static let transcriptSource = Font.system(size: 14, weight: .regular)

    static func captionTarget(_ size: Double, weight: Font.Weight = .medium) -> Font { Font.system(size: size, weight: weight) }
    static func captionSource(_ size: Double) -> Font { Font.system(size: size, weight: .regular) }
    /// The overlay's label row carries digits ("缺口 2.3 秒"), so they are monospaced too.
    static let captionLabel = Font.system(size: 11, weight: .medium).monospacedDigit()
}

/// Line spacing values that produce the line heights in §4 for the given sizes. SF's natural
/// line height is about 1.19×, so the extra is the target minus that.
enum LLLeading {
    static let transcriptTarget: CGFloat = 8     // 17pt → ≈1.7
    static let transcriptTargetSerif: CGFloat = 10
    static let transcriptSource: CGFloat = 5     // 14pt → ≈1.6
    static let body: CGFloat = 4                 // 13pt → ≈1.5 for running explanatory text
    static func caption(_ size: Double) -> CGFloat { CGFloat(size) * 0.26 }        // → ≈1.45
    static func captionSource(_ size: Double) -> CGFloat { CGFloat(size) * 0.21 }  // → ≈1.4
}
