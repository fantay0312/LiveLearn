import Foundation
import AudioDomain
import CaptionDomain

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case text
    case markdown
    case srt
    case vtt

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: return "纯文本（TXT）"
        case .markdown: return "Markdown"
        case .srt: return "字幕 SRT"
        case .vtt: return "字幕 WebVTT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }
}

public enum ExportError: Error, CustomStringConvertible, Equatable {
    case empty
    public var description: String {
        switch self {
        case .empty: return "这次会话没有任何句子，没有可导出的内容"
        }
    }
}

/// Pure text rendering of an archive. Times are session-relative and fixed at export; the
/// session's wall-clock start is written once in the header, never mixed into cue times.
public enum TranscriptExporter {
    public static func render(_ archive: SessionArchive, format: ExportFormat) throws -> String {
        guard !archive.isEmpty else { throw ExportError.empty }
        switch format {
        case .text: return text(archive)
        case .markdown: return markdown(archive)
        case .srt: return subtitles(archive, vtt: false)
        case .vtt: return subtitles(archive, vtt: true)
        }
    }

    /// "LiveLearn 2026-09-06 14-02 Safari · 英语 → 中文.srt", safe for any file system.
    public static func suggestedFileName(_ archive: SessionArchive, format: ExportFormat) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = f.string(from: archive.startedAt)
        var title = archive.title
        for bad in ["/", ":", "\\", "\0"] { title = title.replacingOccurrences(of: bad, with: "-") }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 60 { title = String(title.prefix(60)) }
        if title.isEmpty { title = "会话" }
        return "LiveLearn \(stamp) \(title).\(format.fileExtension)"
    }

    // MARK: - Shared

    static func laneTag(_ archive: SessionArchive, _ laneID: String) -> String {
        guard let lane = archive.lane(laneID) else { return laneID }
        switch lane.sourceKind {
        case .microphone: return "麦克风"
        case .application: return lane.displayName
        case .system: return "系统声"
        }
    }

    static func language(_ code: String?) -> String { LanguageCatalog.name(code) }

    static func gapLabel(_ reason: String) -> String {
        GapReason(rawValue: reason)?.label ?? reason
    }

    static func clock(_ ns: Int64) -> String {
        let total = max(0, ns / 1_000_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%02lld:%02lld", m, s)
    }

    static func duration(_ ns: Int64) -> String {
        let total = max(0, ns / 1_000_000_000)
        return String(format: "%lld:%02lld:%02lld", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func wallClock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    static func headerLines(_ a: SessionArchive) -> [String] {
        var lines = [
            "\(a.title)",
            "开始 \(wallClock(a.startedAt)) · 时长 \(duration(a.durationNs)) · \(a.segmentCount) 句" + (a.incompleteCount > 0 ? "（\(a.incompleteCount) 句未完成）" : "") + (a.gapCount > 0 ? " · 缺口 \(a.gapCount) 处" : ""),
        ]
        for l in a.lanes {
            lines.append("\(l.label) · \(l.displayName) · \(language(l.sourceLanguage)) → \(language(l.targetLanguage)) · \(l.providerName)")
        }
        switch a.outcome {
        case .completed: break
        case .failed: lines.append("会话因错误结束" + (a.failure.map { "：\($0)" } ?? ""))
        case .interrupted: lines.append("上次未正常结束，内容来自自动保存")
        }
        return lines
    }

    // MARK: - TXT

    static func text(_ a: SessionArchive) -> String {
        var out = headerLines(a)
        out.append("")
        let multi = a.lanes.count > 1
        for item in a.items {
            switch item {
            case .segment(let s):
                let tag = multi ? " [\(laneTag(a, s.laneID))]" : ""
                var head = "[\(clock(s.startNs))]\(tag)"
                if s.isIncomplete { head += " [未完成]" }
                if let t = s.translation, !t.text.isEmpty {
                    out.append("\(head) \(t.text)")
                    if !s.sourceText.isEmpty { out.append("    \(s.sourceText)") }
                } else {
                    out.append("\(head) \(s.sourceText)")
                    if !s.isIncomplete { out.append("    （无译文）") }
                }
            case .gap(let g):
                out.append("[\(clock(g.startNs))] —— 缺口 \(String(format: "%.1f", Double(g.durationNs) / 1e9)) 秒 · \(gapLabel(g.reason))")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Markdown

    static func markdown(_ a: SessionArchive) -> String {
        var out: [String] = ["# \(a.title)", ""]
        for line in headerLines(a).dropFirst() { out.append("- \(line)") }
        out.append("")
        let multi = a.lanes.count > 1
        for item in a.items {
            switch item {
            case .segment(let s):
                var head = "**\(clock(s.startNs))**"
                if multi { head += " · \(laneTag(a, s.laneID))" }
                if s.isIncomplete { head += " · 未完成" }
                out.append(head + "  ")
                if let t = s.translation, !t.text.isEmpty {
                    out.append("\(t.text)  ")
                    if !s.sourceText.isEmpty { out.append("*\(s.sourceText)*") }
                } else {
                    out.append("*\(s.sourceText)*")
                }
                out.append("")
            case .gap(let g):
                out.append("> 缺口 \(String(format: "%.1f", Double(g.durationNs) / 1e9)) 秒 · \(gapLabel(g.reason))（\(clock(g.startNs))）")
                out.append("")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - SRT / VTT

    struct Cue {
        var startNs: Int64
        var endNs: Int64
        var lines: [String]
    }

    static let minimumCueNs: Int64 = 600_000_000

    /// Cues in order, each at least 600 ms, never overlapping the previous one. Gaps are not
    /// cues (a subtitle track shows text, not silence); an unfinished sentence says so.
    static func cues(_ a: SessionArchive) -> [Cue] {
        let multi = a.lanes.count > 1
        var cues: [Cue] = []
        var previousEnd: Int64 = 0
        for item in a.items {
            guard case .segment(let s) = item else { continue }
            var lines: [String] = []
            let prefix = multi ? "[\(laneTag(a, s.laneID))] " : ""
            if let t = s.translation, !t.text.isEmpty {
                lines.append(prefix + t.text + (s.isIncomplete ? "（未完成）" : ""))
                if !s.sourceText.isEmpty { lines.append(s.sourceText) }
            } else if !s.sourceText.isEmpty {
                lines.append(prefix + s.sourceText + (s.isIncomplete ? "（未完成）" : ""))
            } else {
                continue
            }
            var start = max(s.startNs, 0)
            if start < previousEnd { start = previousEnd }
            let end = max(s.endNs, start + minimumCueNs)
            previousEnd = end
            cues.append(Cue(startNs: start, endNs: end, lines: lines))
        }
        return cues
    }

    static func stamp(_ ns: Int64, vtt: Bool) -> String {
        let totalMs = max(0, ns / 1_000_000)
        let h = totalMs / 3_600_000, m = (totalMs % 3_600_000) / 60_000, s = (totalMs % 60_000) / 1000, ms = totalMs % 1000
        return String(format: vtt ? "%02lld:%02lld:%02lld.%03lld" : "%02lld:%02lld:%02lld,%03lld", h, m, s, ms)
    }

    static func subtitles(_ a: SessionArchive, vtt: Bool) -> String {
        var out: [String] = []
        if vtt {
            out.append("WEBVTT")
            out.append("")
            out.append("NOTE \(a.title) · \(wallClock(a.startedAt))")
            out.append("")
        }
        for (i, cue) in cues(a).enumerated() {
            out.append("\(i + 1)")
            out.append("\(stamp(cue.startNs, vtt: vtt)) --> \(stamp(cue.endNs, vtt: vtt))")
            out.append(contentsOf: cue.lines)
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
