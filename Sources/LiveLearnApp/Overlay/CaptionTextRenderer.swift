import SwiftUI

/// Solid glyphs with an edge of the opposite tone. The ink is the user's and never changes with
/// the picture behind it; off a plate, the edge is what keeps it readable there, on bright
/// frames and dark ones alike. A quieter context line fades as one piece, edge and fill
/// together: a translucent fill over a full edge read as grey letters with darker, smeared rims.
/// TextRenderer keeps one layout and one accessibility element, including CJK wrapping.
struct CaptionTextRenderer: TextRenderer {
    struct Edge: Equatable {
        var hex: UInt32
        var width: Double
        var opacity: Double = 1
    }

    /// One blurred copy of the glyphs under the fill.
    struct Halo: Equatable {
        var radius: Double
        var opacity: Double
        var y: Double = 0
    }

    var edges: [Edge]
    var haloHex: UInt32? = nil
    var halos: [Halo] = []
    var lineOpacity: Double = 1

    var displayPadding: EdgeInsets {
        let reach = halos.map { $0.radius * 3 + abs($0.y) }.max() ?? 0
        let padding = max(edges.map(\.width).max() ?? 0, reach) + 1
        return EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)
    }

    static func contrastingHex(_ hex: String) -> UInt32 {
        let luminance = HexColor.luminance(hex)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? 0x000000 : 0xFFFFFF
    }

    /// The look of a film subtitle: a thin, crisp contour and a short shadow under it, both of
    /// the tone opposite the ink. The blurred glow this replaces kept the letters readable but
    /// smeared grey around them on bright frames.
    static func automatic(hex: String, size: Double, emphasis: Double = 1) -> Self {
        let size = size.isFinite ? min(80, max(8, size)) : 26
        let tone = contrastingHex(hex)
        return Self(edges: [Edge(hex: tone, width: min(1.6, max(0.7, size * 0.035)), opacity: 0.8)],
                    haloHex: tone, halos: [Halo(radius: min(4, max(1.4, size * 0.085)), opacity: 0.5, y: size * 0.045)],
                    lineOpacity: emphasis)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard lineOpacity < 1 else { return paint(layout, in: &context) }
        var group = context
        group.opacity *= lineOpacity
        group.drawLayer { paint(layout, in: &$0) }
    }

    private func paint(_ layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            if let haloHex {
                for halo in halos {
                    var shadow = context
                    shadow.addFilter(.shadow(color: Color(hex: haloHex).opacity(halo.opacity), radius: halo.radius,
                                             x: 0, y: halo.y, options: .shadowOnly))
                    shadow.draw(line)
                }
            }
            for edge in edges where edge.width > 0 {
                // Offset copies are shadow-only: they do not repaint the glyph's fill.
                for direction in 0..<12 {
                    let angle = Double(direction) * .pi / 6
                    var stroke = context
                    stroke.addFilter(.shadow(color: Color(hex: edge.hex).opacity(edge.opacity), radius: 0,
                                             x: cos(angle) * edge.width, y: sin(angle) * edge.width,
                                             options: .shadowOnly))
                    stroke.draw(line)
                }
            }
            // Drawn last so contrast protection never hollows out the glyph.
            context.draw(line)
        }
    }
}
