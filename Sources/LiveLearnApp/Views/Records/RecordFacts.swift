import Foundation
import AudioDomain
import SessionStorage

/// How a record describes itself in words, shared by the rail and the reading column's masthead
/// so the two never disagree about a record's time, length or sources.
enum RecordFacts {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "M月d日"
        return f
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = "EEE"
        return f
    }()

    /// "17:05".
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 今天 / 昨天 / 9月5日 / 2025年12月31日.
    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return date(day)
    }

    /// "9月27日 周六" (the year only when it is not this one). A date rather than 今天, since a
    /// record is read back on other days too.
    static func day(_ date: Date) -> String {
        "\(self.date(date)) \(weekdayFormatter.string(from: date))"
    }

    /// The masthead's opening line: "9月27日 周六 17:05".
    static func masthead(_ r: SessionRecord) -> String {
        "\(day(r.startedAt)) \(time(r.startedAt))"
    }

    private static func date(_ day: Date) -> String {
        let calendar = Calendar.current
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        return (sameYear ? dayFormatter : dayWithYearFormatter).string(from: day)
    }

    private static func name(_ lane: SessionArchive.Lane) -> String {
        switch lane.kind {
        case AudioSourceKind.microphone.rawValue: return "麦克风"
        case AudioSourceKind.system.rawValue: return "系统声"
        default: return lane.displayName
        }
    }

    /// Where the sound came from: "Safari", "Safari + 麦克风".
    static func sourceNames(_ r: SessionRecord) -> String {
        let lanes = r.archive.lanes
        return lanes.isEmpty ? r.title : lanes.map(name).joined(separator: " + ")
    }

    /// Where the sound came from and which way it was translated, in as few words as the record
    /// allows: "Safari · 英语 → 中文", or "Safari + 麦克风" for two lanes.
    static func sources(_ r: SessionRecord) -> String {
        let lanes = r.archive.lanes
        if lanes.count == 1, let lane = lanes.first {
            return "\(name(lane)) · \(StatusCopy.direction(lane.sourceLanguage, lane.targetLanguage))"
        }
        return sourceNames(r)
    }

    /// Sentences, length, sources: what a person needs to tell two records apart. The full
    /// summary (the masthead and VoiceOver); the rail's meta line is `meta`.
    static func detail(_ r: SessionRecord) -> String {
        var parts = ["\(r.segmentCount) 句", StatusCopy.clock(r.durationNs), sources(r)]
        if r.incompleteCount > 0 { parts.insert("\(r.incompleteCount) 句未完成", at: 1) }
        return parts.joined(separator: " · ")
    }

    /// The rail's second line: "17:05 · 6 句 · 6:12 · Safari". The time leads (the title above
    /// is a sentence now, not the time) and the direction stays in the masthead, so the line
    /// fits the rail without an ellipsis.
    static func meta(_ r: SessionRecord) -> String {
        var parts = [time(r.startedAt), "\(r.segmentCount) 句", StatusCopy.clock(r.durationNs), sourceNames(r)]
        if r.incompleteCount > 0 { parts.insert("\(r.incompleteCount) 句未完成", at: 2) }
        return parts.joined(separator: " · ")
    }

    /// The rail's title: the first translated sentence, which is what a person remembers a
    /// conversation by; the first recognised sentence when nothing was translated; nil for an
    /// empty record (the caller falls back to the time). Returns at the first translation,
    /// which is nearly always the first sentence, so a long record costs no more than a short one.
    static func headline(_ r: SessionRecord) -> String? {
        var source: String?
        for item in r.archive.items {
            guard case .segment(let segment) = item else { continue }
            if let text = segment.translation?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
            if source == nil {
                let text = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { source = text }
            }
        }
        return source
    }
}
