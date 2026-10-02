import SwiftUI

private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StaticMotionTimeKey: EnvironmentKey {
    static let defaultValue = 0.0
}

extension EnvironmentValues {
    var staticMotionTime: Double {
        get { self[StaticMotionTimeKey.self] }
        set { self[StaticMotionTimeKey.self] = newValue }
    }
    /// True while rendering design previews offscreen: ScrollView / lazy stacks / AppKit-backed
    /// controls do not draw there, so containers fall back to plain SwiftUI equivalents.
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

/// ScrollView in the app, a plain top-aligned stack when rendering previews. Scroll bars follow
/// the system preference (overlay bars appear only while scrolling), so the resting page stays
/// quiet and a reader who asked for bars gets them.
struct ScrollContainer<Content: View>: View {
    @Environment(\.staticRender) private var staticRender
    var showsIndicators = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        if staticRender {
            // GeometryReader pins its child to the top-left, so a page taller than the frame
            // overflows downward (like a scroll view at rest) instead of being centered.
            GeometryReader { geo in
                VStack(spacing: 0) {
                    content()
                }
                .frame(width: geo.size.width, alignment: .top)
            }
            .clipped()
        } else {
            ScrollView(.vertical) { content() }
                .scrollIndicators(showsIndicators ? .automatic : .hidden)
        }
    }
}
