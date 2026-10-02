import SwiftUI

/// Frequent destinations, visually separate from the session's transport controls.
struct MainNavigationDock: View {
    let openRecords: () -> Void
    let goHome: () -> Void
    var previewStarPoints: [CGPoint]? = nil
    var previewTime: Double = 0
    @Environment(AppModel.self) private var model

    private var selection: Int {
        switch model.mainPage {
        case .transcript: 0
        case .home: 1
        case .vocabulary: 2
        }
    }

    var body: some View {
        ZStack {
            OrbitRowStack {
                destination("记录", selected: model.mainPage == .transcript, action: openRecords)
                destination("首页", selected: model.mainPage == .home, prominent: true, action: goHome)
                destination("词汇", selected: model.mainPage == .vocabulary) { model.requestVocabularyWindow() }
            }
            .background {
                if let previewStarPoints {
                    NavigationStarCanvas(points: previewStarPoints, time: previewTime)
                } else {
                    NavigationStarField(selection: selection, renderer: .metal)
                }
            }
            .frame(maxWidth: .infinity)

            DockUtilityActions()
            .padding(.horizontal, 24)
        }
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func destination(_ title: String, selected: Bool = false, prominent: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: prominent ? 14 : 12, weight: .medium))
                .frame(width: OrbitRow.cell.width, height: OrbitRow.cell.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(DockButtonStyle(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title == "记录" ? "查看实时字幕与历史记录" : title)
    }
}
