import SessionDomain

enum SessionActionAppearance: String, CaseIterable {
    case start, pause, resume, stop, preparing, connecting, finishing

    var title: String {
        switch self {
        case .start: "开始翻译"
        case .pause: "暂停"
        case .resume: "继续"
        case .stop: "停止"
        case .preparing: "正在准备"
        case .connecting: "正在连接"
        case .finishing: "正在收尾"
        }
    }

    var isBusy: Bool { self == .preparing || self == .connecting || self == .finishing }
    var hasLivingForm: Bool { self != .stop }
    static func canPauseOrResume(_ state: SessionState) -> Bool {
        [.running, .degraded, .reconnecting, .paused].contains(state)
    }
    static func canStop(_ state: SessionState) -> Bool {
        [.preparing, .connecting, .running, .degraded, .reconnecting, .paused].contains(state)
    }
    var symbol: String {
        switch self {
        case .pause: "pause.fill"
        case .stop, .finishing: "stop.fill"
        default: "play.fill"
        }
    }

    static func primary(for state: SessionState) -> Self {
        switch state {
        case .idle, .completed, .failed: .start
        case .preparing: .preparing
        case .connecting: .connecting
        case .paused: .resume
        case .draining, .stopping: .finishing
        case .running, .degraded, .reconnecting: .pause
        }
    }
}

extension AppModel {
    var canPauseOrResume: Bool { !isReconfiguringSession && SessionActionAppearance.canPauseOrResume(sessionState) }
    var canStop: Bool { !isReconfiguringSession && SessionActionAppearance.canStop(sessionState) }
}
