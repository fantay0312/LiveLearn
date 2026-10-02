import Foundation
import AudioDomain
import CaptionDomain
import SessionDomain

/// Design language §8: state text says what is true, never "AI is working".
enum StatusCopy {
    static func session(_ s: SessionSnapshot) -> String {
        switch s.state {
        case .idle: return "未开始"
        case .preparing, .connecting:
            // A lane waiting on a consent dialog explains itself; otherwise the session's own line.
            if let waiting = s.lanes.first(where: { $0.capture.state == .recovering })?.capture.detail, !waiting.isEmpty { return waiting }
            return s.detail ?? (s.state == .preparing ? "正在检查权限与引擎" : "正在连接引擎")
        case .paused: return s.lanes.contains { !$0.isLocal } ? "已暂停 · 未上传" : "已暂停 · 音频不送入引擎"
        case .draining: return "正在收尾最后一句"
        case .stopping: return "正在停止"
        case .completed:
            if let d = s.detail, !d.isEmpty { return "已结束 · \(d)" }
            return "已结束 · 未保存"
        case .failed: return s.failure ?? "已停止"
        case .reconnecting:
            let attempts = s.lanes.map(\.reconnectAttempts).max() ?? 1
            return "连接中断，正在重连（第 \(attempts) 次）"
        case .degraded:
            let impaired = s.lanes.first { $0.providerLink == .failed || $0.capture.state == .failed || $0.capture.state == .permissionRequired || $0.capture.state == .sourceUnavailable || $0.capture.state == .recovering }
            let ok = s.lanes.first { $0.id != impaired?.id }
            if let f = impaired, let o = ok {
                let verb = f.capture.state == .sourceUnavailable || f.capture.state == .recovering ? "等待恢复" : "已停止"
                return "\(f.configuration.source.kind.label)通道\(verb) · \(o.configuration.source.kind.label)通道继续"
            }
            if let f = impaired {
                // Single lane that may come back on its own: say what it is waiting for.
                if let d = f.capture.detail, !d.isEmpty { return d }
                if f.capture.state == .sourceUnavailable { return "\(f.configuration.source.displayName) 已退出；重新打开后会自动继续" }
                return f.lastError ?? "通道等待恢复"
            }
            return "部分通道已停止"
        case .running:
            return runningDetail(s)
        }
    }

    private static func runningDetail(_ s: SessionSnapshot) -> String {
        // Prefer the lane that has something to say; application lane first.
        let lanes = s.lanes.sorted { ($0.configuration.source.kind == .application ? 0 : 1) < ($1.configuration.source.kind == .application ? 0 : 1) }
        for lane in lanes {
            let name = lane.configuration.source.displayName
            switch lane.capture.state {
            case .permissionRequired: return lane.configuration.source.kind == .microphone ? "需要麦克风权限" : "需要系统音频权限"
            case .sourceUnavailable: return "\(name) 已退出"
            case .waitingForAudio: return lane.configuration.source.kind == .microphone ? "等待你说话" : "等待 \(name) 发声"
            case .recovering: return lane.capture.detail ?? "正在恢复采集"
            default: break
            }
        }
        if let current = s.captions.items.last, case .segment(let seg) = current, seg.presentationState == .awaitingTranslation {
            return "翻译中"
        }
        if !lanes.isEmpty {
            // Name every lane that is being listened to, not just the first one (dual-lane run).
            let names = lanes.map { $0.configuration.source.kind == .microphone ? "你" : $0.configuration.source.displayName }
            if lanes.allSatisfy({ $0.capture.state == .sourceIdle }) { return "\(names.joined(separator: " 与 ")) 暂时没有声音" }
            let active = zip(lanes, names).filter { $0.0.capture.state != .sourceIdle }.map(\.1)
            return "正在听 · \(active.joined(separator: " 与 "))"
        }
        return "正在听"
    }

    static func lane(_ l: LaneStatus) -> String {
        switch l.capture.state {
        case .idle: return "未开始"
        case .waitingForAudio: return "等待声音"
        case .capturing: return "采集中"
        case .sourceIdle: return "暂无声音"
        case .sourceUnavailable: return "来源不可用"
        case .permissionRequired: return "需要权限"
        case .recovering: return "正在恢复"
        case .stopped: return "已停止"
        case .failed: return "失败"
        }
    }

    static func link(_ l: ProviderLinkState) -> String {
        switch l {
        case .idle: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reconnecting: return "重连中"
        case .closed: return "已关闭"
        case .failed: return "失败"
        }
    }

    static func presentation(_ p: PresentationState) -> String {
        switch p {
        case .listening: return "正在听"
        case .preview: return "识别中"
        case .stable: return "稳定"
        case .awaitingTranslation: return "翻译中"
        case .final: return ""
        case .frozen: return "已冻结"
        }
    }

    /// Segment status for the overlay: an unfinished sentence says so instead of "已冻结".
    static func segment(_ s: CaptionSegment) -> String {
        s.isIncomplete ? "未完成" : presentation(s.presentationState)
    }

    static func gap(_ g: CaptionGap) -> String {
        let seconds = Double(g.durationNs) / 1_000_000_000
        let reason = GapReason(rawValue: g.reason)?.label ?? g.reason
        return String(format: "缺口 %.1f 秒 · %@", seconds, reason)
    }

    static func timestamp(_ ns: Int64) -> String {
        let total = max(0, ns / 1_000_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// The one clock: "0:46" under an hour, "1:02:15" after — a session's age as it runs
    /// (Home's status line, the horizon, the rail's live row, the menu bar) and a record's length
    /// (rail, masthead, horizon) read the same, with no leading hour of zeros. Set it in
    /// monospaced digits so a ticking clock does not shift its neighbours.
    static func clock(_ ns: Int64) -> String {
        let total = max(0, ns / 1_000_000_000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%lld:%02lld:%02lld", h, m, s) : String(format: "%lld:%02lld", m, s)
    }

    static func seconds(_ ns: Int64) -> String {
        String(format: "%.1f 秒", Double(ns) / 1_000_000_000)
    }

    static func millis(_ ns: Int64) -> String {
        "\(ns / 1_000_000) ms"
    }

    static func language(_ code: String?) -> String { LanguageCatalog.name(code) }

    static func direction(_ from: String?, _ to: String) -> String {
        "\(language(from)) → \(language(to))"
    }
}
