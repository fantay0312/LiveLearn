import Foundation

struct DictationMeter: Equatable {
    static let weights = [0.5, 0.8, 1.0, 0.75, 0.55]
    private(set) var level = 0.0
    private var sample: UInt64 = 0

    mutating func consume(rms: Float) {
        let rms = rms.isFinite ? max(0, Double(rms)) : 0
        let target = rms < 0.001 ? 0 : min(1, sqrt(rms) * 3)
        level += (target - level) * (target > level ? 0.4 : 0.15)
        if level < 0.002 { level = 0 }
        sample &+= 1
    }

    var heights: [CGFloat] {
        Self.weights.enumerated().map { index, weight in
            // Jitter changes only with actual audio packets; silence never animates on a timer.
            let hash = (sample &* 6364136223846793005) &+ UInt64(index * 1447)
            let jitter = 1 + (Double((hash >> (index + 8)) % 1000) / 999 - 0.5) * 0.08
            return 4 + 28 * min(1, level * weight * jitter)
        }
    }
}

enum DictationLanguage: String, CaseIterable, Identifiable {
    case simplified = "zh-CN", traditional = "zh-TW", english = "en-US", japanese = "ja-JP", korean = "ko-KR", automatic = "auto"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .simplified: "简体中文"
        case .traditional: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .automatic: "自动 / 多语言"
        }
    }
}
