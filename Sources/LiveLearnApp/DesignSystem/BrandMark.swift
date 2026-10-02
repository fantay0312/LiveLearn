import AppKit
import SwiftUI

struct LiveLearnMark: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(0..<LLBrandGeometry.parts.count, id: \.self) { index in
                    BrandStroke(index: index)
                        .fill(LinearGradient(colors: index == 0 ? [theme.ink, theme.starBlue] : [theme.starBlue, theme.ink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Path(LLBrandGeometry.nucleus(in: CGRect(origin: .zero, size: geometry.size))).fill(theme.ink)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct BrandStroke: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        Path(LLBrandGeometry.path(for: index, in: rect))
    }
}

/// Template PDFs let macOS supply the menu bar's correct color in every appearance.
@MainActor
enum LLBrandAssets {
    static let menuBarIdle = menuImage(named: "MenuBarTemplate", active: false)
    static let menuBarActive = menuImage(named: "MenuBarActiveTemplate", active: true)

    private static func menuImage(named name: String, active: Bool) -> NSImage {
        let image: NSImage
        if let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
           let resource = NSImage(contentsOf: url) {
            image = resource
        } else {
            // Keeps bare SwiftPM previews functional as well as the packaged app.
            image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.black.cgColor)
                let rect = CGRect(x: -1, y: -1, width: 20, height: 20)
                for index in LLBrandGeometry.parts.indices {
                    context.addPath(LLBrandGeometry.path(for: index, in: rect))
                    context.fillPath()
                }
                context.addPath(LLBrandGeometry.nucleus(in: rect, active: active))
                context.fillPath()
                return true
            }
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
