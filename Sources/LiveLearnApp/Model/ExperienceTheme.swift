import Foundation

enum ExperienceTheme: String, CaseIterable, Identifiable, Sendable {
    case stellar, wilds

    var id: String { rawValue }
    var title: String { self == .stellar ? "星际探索" : "旷野探索" }
    var shortTitle: String { self == .stellar ? "星际" : "旷野" }
    var note: String {
        self == .stellar ? "深邃星空 · 行星与轨道" : "塞尔达风格 · 山野与古迹"
    }
    var artworkName: String { "\(rawValue)-landscape" }
}
