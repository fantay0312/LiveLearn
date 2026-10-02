import SwiftUI

/// A transparent action group locked to Home's axis; individual controls carry their own light.
///
/// The first control is the primary and sits on the rail's centre line; any others hang to its
/// right as satellites (Stop beside Pause). The rail reserves the satellites' width on the left
/// too, so a rail centred on the page keeps its primary on the core's axis in every state —
/// starting a session never moves the capsule sideways.
struct SessionControlRail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        AxisRailLayout {
            content()
        }
        .accessibilityElement(children: .contain)
    }
}

/// The rail's geometry (`SessionControlRail`): the primary centred, satellites `spacing` apart
/// to its right, vertically centred. Given more room than it asks for, the rail centres itself
/// in it, so the primary stays on the axis of whatever holds it.
struct AxisRailLayout: Layout {
    var spacing: CGFloat = 12

    /// The rail's size and each control's frame in it, for controls of `sizes` (first = primary).
    static func arrange(_ sizes: [CGSize], spacing: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        guard let primary = sizes.first else { return (.zero, []) }
        let reach = sizes.dropFirst().reduce(0) { $0 + spacing + $1.width }
        let height = sizes.map(\.height).max() ?? 0
        var x = reach
        var frames: [CGRect] = []
        for (index, item) in sizes.enumerated() {
            if index > 0 { x += spacing }
            frames.append(CGRect(x: x, y: (height - item.height) / 2, width: item.width, height: item.height))
            x += item.width
        }
        return (CGSize(width: primary.width + reach * 2, height: height), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.arrange(subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rail = Self.arrange(subviews.map { $0.sizeThatFits(.unspecified) }, spacing: spacing)
        let dx = (bounds.width - rail.size.width) / 2, dy = (bounds.height - rail.size.height) / 2
        for (subview, frame) in zip(subviews, rail.frames) {
            subview.place(at: CGPoint(x: bounds.minX + dx + frame.minX, y: bounds.minY + dy + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
}
