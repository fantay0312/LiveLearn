import SwiftUI

/// Sequential sound waves say listening; the real level trace stays in the source row.
struct ListeningMark: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.staticRender) private var staticRender

    var body: some View {
        Image(systemName: "speaker.wave.2")
            .font(.system(size: 19, weight: .medium))
            .symbolEffect(.variableColor.iterative, options: .repeating.speed(0.65), isActive: !reduceMotion && !staticRender)
            .foregroundStyle(color)
            .frame(width: 32, height: 28)
    }
}
