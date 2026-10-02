import SwiftUI

struct DictationFold<Content: View>: View {
    let title: String
    var summary: String = ""
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded { NSApp.keyWindow?.makeFirstResponder(nil) }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(title).font(LLFont.body).foregroundStyle(theme.ink)
                    Spacer()
                    Text(summary).font(LLFont.label).foregroundStyle(theme.ink3).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(theme.ink3)
                }.frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(InlineButtonStyle())
            .accessibilityLabel(title).accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(.top, 12).padding(.bottom, 8).transition(.opacity)
            }
        }
    }
}
