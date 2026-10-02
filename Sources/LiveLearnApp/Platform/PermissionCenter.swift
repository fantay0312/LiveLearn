import Foundation
import AppKit
import AVFoundation
import AudioDomain
import SessionDomain
import MacAudio

/// One concrete thing the user can do to get unstuck.
enum RecoveryAction: Equatable {
    case openMicrophoneSettings
    case openAudioCaptureSettings
    case openLocalModels
    case openEngineSettings
    case reselectMicrophone
    case openSessionsFolder

    var label: String {
        switch self {
        case .openMicrophoneSettings: return "打开麦克风权限设置"
        case .openAudioCaptureSettings: return "打开系统录音权限设置"
        case .openLocalModels: return "打开本地模型设置"
        case .openEngineSettings: return "打开引擎设置"
        case .reselectMicrophone: return "重新选择麦克风"
        case .openSessionsFolder: return "打开记录文件夹"
        }
    }
}

/// Failure explained in the user's words, with the one action that fixes it.
struct RecoveryAdvice: Equatable {
    var title: String
    var detail: String
    var action: RecoveryAction?
}

/// Classifies permission and capture failures and knows where the fix lives in System
/// Settings. Never requests a permission on its own: the microphone is asked for when a
/// microphone lane starts, system audio when the first tap is created, and nothing else.
enum PermissionCenter {
    /// Verified on macOS 27 beta: opens 系统设置 › 隐私与安全性 › 麦克风.
    static let microphoneSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    /// Verified on macOS 27 beta: opens 系统设置 › 隐私与安全性 › 录屏与系统录音.
    static let audioCaptureSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    static func microphoneStatusText() -> String {
        switch MicrophoneCapture.authorizationStatus {
        case .authorized: return "已允许"
        case .denied: return "已拒绝"
        case .restricted: return "受限（由系统策略禁止）"
        case .notDetermined: return "尚未询问；启用麦克风来源开始会话时会询问"
        @unknown default: return "未知"
        }
    }

    /// Why a microphone session cannot start right now, before any lane is built.
    static func microphoneBlocker() -> RecoveryAdvice? {
        switch MicrophoneCapture.authorizationStatus {
        case .denied:
            return RecoveryAdvice(title: "麦克风权限已被拒绝", detail: "在 系统设置 › 隐私与安全性 › 麦克风 中允许 LiveLearn，然后回来按左上角的朱色三角开始。", action: .openMicrophoneSettings)
        case .restricted:
            return RecoveryAdvice(title: "麦克风被系统策略禁止", detail: "这台电脑的管理策略不允许应用使用麦克风；可改用「听懂电脑里的内容」场景。", action: nil)
        default:
            return nil
        }
    }

    /// Advice for a lane in trouble, or nil when it is fine or will recover on its own.
    static func advice(for lane: LaneStatus, elapsedNs: Int64) -> RecoveryAdvice? {
        let kind = lane.configuration.source.kind
        let name = lane.configuration.source.displayName
        switch lane.capture.state {
        case .permissionRequired:
            if kind == .microphone {
                return RecoveryAdvice(title: "需要麦克风权限", detail: "在 系统设置 › 隐私与安全性 › 麦克风 中允许 LiveLearn，再重新开始。", action: .openMicrophoneSettings)
            }
            return RecoveryAdvice(title: "需要系统音频录制权限", detail: "在 系统设置 › 隐私与安全性 › 录屏与系统录音 中允许 LiveLearn，再重新开始。只会采集你选定的来源。", action: .openAudioCaptureSettings)
        case .failed:
            let error = lane.lastError ?? lane.capture.detail ?? ""
            if kind == .microphone, error.contains("找不到所选麦克风") || error.contains("重新选择") {
                return RecoveryAdvice(title: "所选麦克风不在了", detail: error, action: .reselectMicrophone)
            }
            if kind == .microphone, error.contains("持续变化") {
                return RecoveryAdvice(title: "麦克风一直在切换", detail: "耳机在通话与音乐模式之间来回切换时会这样。等它稳定，或换用内置麦克风后重新开始。", action: .reselectMicrophone)
            }
            if kind != .microphone, error.contains("Process Tap") || error.contains("系统音频录制") {
                return RecoveryAdvice(title: "无法建立系统音频采集", detail: error, action: .openAudioCaptureSettings)
            }
            return RecoveryAdvice(title: "\(kind.label)通道失败", detail: error.isEmpty ? "请重新开始；若反复出现，导出诊断包。" : error, action: nil)
        case .waitingForAudio:
            // Tap built, target says it is playing, yet no callback for a while: the classic
            // shape of a denied "system audio recording" grant (the tap is created but silent).
            if kind != .microphone, lane.capture.callbackCount == 0, elapsedNs > 10_000_000_000,
               let d = lane.capture.detail, d.contains("尚未收到音频回调") {
                return RecoveryAdvice(title: "\(name) 在发声，但没有音频到达", detail: "可能没有获得「录屏与系统录音」权限。若系统从未询问，或你曾经拒绝，请在系统设置里允许 LiveLearn 后重新开始。", action: .openAudioCaptureSettings)
            }
            return nil
        default:
            return nil
        }
    }

    /// Advice for a session that failed to start at all (no lane ever produced audio).
    static func advice(forSession snapshot: SessionSnapshot) -> RecoveryAdvice? {
        guard snapshot.state == .failed else { return nil }
        for lane in snapshot.lanes {
            if let a = advice(for: lane, elapsedNs: snapshot.elapsedNs) { return a }
        }
        guard let failure = snapshot.failure else { return nil }
        if failure.contains("麦克风权限") {
            return RecoveryAdvice(title: "需要麦克风权限", detail: failure, action: .openMicrophoneSettings)
        }
        if failure.contains("系统音频录制") || failure.contains("Process Tap") {
            return RecoveryAdvice(title: "需要系统音频录制权限", detail: failure, action: .openAudioCaptureSettings)
        }
        if failure.contains("本地模型") || failure.contains("尚未下载") || failure.contains("语言包") {
            return RecoveryAdvice(title: "本机引擎缺少模型", detail: failure, action: .openLocalModels)
        }
        if failure.contains("找不到所选麦克风") {
            return RecoveryAdvice(title: "所选麦克风不在了", detail: failure, action: .reselectMicrophone)
        }
        return nil
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
