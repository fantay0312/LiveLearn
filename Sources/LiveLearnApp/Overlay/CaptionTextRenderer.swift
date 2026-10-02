import SwiftUI

/// Solid glyphs with a quiet shadow. Automatic ink adapts to the backdrop; context opacity
/// affects the fill without turning its contrast protection into a hard outline.
/// TextRenderer keeps one layout and one accessibility element, including CJK wrapping.
struct CaptionTextRenderer: TextRenderer {
    struct Edge: Equatable {
        var hex: UInt32
        var width: Double
    }

    var edges: [Edge]
    var shadowHex: UInt32? = nil
    var shadowRadius: Double = 0
    var shadowOpacity: Double = 0.68
    var foregroundOpacity: Double = 1

    var displayPadding: EdgeInsets {
        let padding = max(edges.map(\.width).max() ?? 0, shadowRadius * 3) + 1
        return EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
    }

    static func contrastingHex(_ hex: String) -> UInt32 {
        let luminance = HexColor.luminance(hex)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? 0x000000 : 0xFFFFFF
    }

    static func automatic(hex: String, size: Double, emphasis: Double = 1) -> Self {
        let size = size.isFinite ? min(80, max(8, size)) : 26
        let contrast = contrastingHex(hex)
        return Self(edges: [], shadowHex: contrast, shadowRadius: min(1.3, max(0.6, size / 26)),
                    shadowOpacity: 0.45, foregroundOpacity: emphasis)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            if let shadowHex {
                var shadow = context
                shadow.addFilter(.shadow(color: Color(hex: shadowHex).opacity(shadowOpacity), radius: shadowRadius,
                                         x: 0, y: 1, options: .shadowOnly))
                // Draw the fill last so contrast protection never hollows out the glyph.
                shadow.draw(line)
            }
            for edge in edges where edge.width > 0 {
                // Offset copies are shadow-only: they do not repaint the glyph's fill.
                for direction in 0..<12 {
                    let angle = Double(direction) * .pi / 6
                    var stroke = context
                    stroke.addFilter(.shadow(color: Color(hex: edge.hex), radius: 0,
                                             x: cos(angle) * edge.width, y: sin(angle) * edge.width,
                                             options: .shadowOnly))
                    stroke.draw(line)
                }
            }
            var foreground = context
            foreground.opacity *= foregroundOpacity
            foreground.draw(line)
        }
    }
}
