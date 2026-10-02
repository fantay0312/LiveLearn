import Foundation
import AudioDomain
import MacAudio

/// "检查音源": runs the real capture path for a few seconds and says what happened, in
/// numbers the user can read. Nothing is transcribed, uploaded or saved. Uses the same
/// permission rules as a session: a microphone check asks for the microphone, an app or
/// system check asks for system audio recording, never the other way around.
enum SourceCheck {
    enum Outcome: Equatable { case audible, silent, partial, failed, cancelled }
    struct Report: Equatable {
        var lines: [String]
        var advice: RecoveryAdvice?
        var ok: Bool
        var outcome: Outcome

        init(lines: [String], advice: RecoveryAdvice?, ok: Bool, outcome: Outcome? = nil) {
            self.lines = lines; self.advice = advice; self.ok = ok
            self.outcome = outcome ?? (ok ? .audible : .failed)
        }

        var title: String {
            switch outcome {
            case .audible: return "已检测到声音"
            case .silent: return "音源已连通，暂时没有声音"
            case .partial: return "部分音源暂时没有声音"
            case .failed: return "音源需要处理"
            case .cancelled: return "检查已取消"
            }
        }
        var summary: String {
            switch outcome {
            case .audible: return "音频可以正常进入，可以开始翻译。"
            case .silent: return "播放内容或对着麦克风说话后，再检查一次。"
            case .partial: return "已检测到声音；另一个音源当前静音，可在详细信息中查看。"
            case .failed: return advice?.detail ?? "请确认所选音源可用，并检查录音权限。"
            case .cancelled: return "音源检查已经停止。"
            }
        }

        static func combining(_ reports: [Report]) -> Report {
            let outcome: Outcome
            if reports.contains(where: { $0.outcome == .cancelled }) { outcome = .cancelled }
            else if reports.isEmpty || reports.contains(where: { !$0.ok }) { outcome = .failed }
            else if reports.contains(where: { $0.outcome == .audible }) {
                outcome = reports.contains(where: { $0.outcome == .silent }) ? .partial : .audible
            } else { outcome = .silent }
            return Report(lines: reports.flatMap(\.lines), advice: reports.compactMap(\.advice).first,
                          ok: outcome != .failed && outcome != .cancelled, outcome: outcome)
        }
    }

    private final class Stats: @unchecked Sendable {
        private let lock = NSLock()
        var packets = 0
        var callbacks: UInt64 = 0
        var maxPeak: Float = 0
        var audible = 0
        var format: String?
        var failure: CaptureFailure?
        var lastHealth: CaptureHealth?
        func snapshot() -> (packets: Int, maxPeak: Float, audible: Int, format: String?, failure: CaptureFailure?, lastHealth: CaptureHealth?) {
            lock.withLock { (packets, maxPeak, audible, format, failure, lastHealth) }
        }
        func note(_ e: CaptureEvent) {
            lock.withLock {
                switch e {
                case .started(_, let f): format = f.summary
                case .packet(let p):
                    packets += 1
                    let en = p.samples.energy()
                    maxPeak = max(maxPeak, en.peak)
                    if AudioLevel.isAudible(rms: en.rms) { audible += 1 }
                case .health(let h):
                    lastHealth = h
                    callbacks = max(callbacks, h.callbackCount)
                case .failed(let f): failure = f
                case .gap, .stopped: break
                }
            }
        }
    }

    static func run(_ source: AudioSourceDescriptor, seconds: Int = 3) async -> Report {
        let anchor = MonotonicClock.nowNs()
        let capture: any AudioCapture = source.kind == .microphone
            ? MicrophoneCapture(laneID: "check", sessionAnchorNs: anchor)
            : ProcessTapCapture(laneID: "check", sessionAnchorNs: anchor)
        return await run(source, seconds: seconds, capture: capture)
    }

    /// Injectable capture keeps cancellation and report tests independent of hardware.
    static func run(_ source: AudioSourceDescriptor, seconds: Int, capture: any AudioCapture) async -> Report {
        let accumulator = Stats()
        let consumer = Task {
            for await event in capture.events { accumulator.note(event) }
        }
        defer { consumer.cancel() }
        do {
            try Task.checkCancellation()
            try await capture.prepare(source)
            try Task.checkCancellation()
            try await capture.start()
            try Task.checkCancellation()
        } catch is CancellationError {
            await capture.stop()
            return Report(lines: [], advice: nil, ok: false, outcome: .cancelled)
        } catch let f as CaptureFailure {
            await capture.stop()
            return Report(lines: ["\(source.tag)：启动失败 · \(f.message)"], advice: advice(for: f, source: source), ok: false)
        } catch {
            await capture.stop()
            return Report(lines: ["\(source.tag)：启动失败 · \(error)"], advice: nil, ok: false)
        }
        try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
        await capture.stop()
        if Task.isCancelled { return Report(lines: [], advice: nil, ok: false, outcome: .cancelled) }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stats = accumulator.snapshot()

        if let f = stats.failure {
            return Report(lines: ["\(source.tag)：\(f.message)"], advice: advice(for: f, source: source), ok: false)
        }
        var lines: [String] = []
        let format = stats.format ?? "—"
        if stats.packets == 0 {
            let waiting = stats.lastHealth?.detail ?? "没有收到任何音频回调"
            lines.append("\(source.tag)：\(seconds) 秒内没有音频 · \(waiting)")
            var advice: RecoveryAdvice? = nil
            if source.kind != .microphone {
                advice = RecoveryAdvice(title: "没有收到 \(source.displayName) 的音频", detail: "确认它正在播放声音。若它在发声但这里仍为 0，可能是「录屏与系统录音」权限没有授予。", action: .openAudioCaptureSettings)
            }
            return Report(lines: lines, advice: advice, ok: false)
        }
        let peak = String(format: "%.2f", stats.maxPeak)
        if stats.audible == 0 {
            lines.append("\(source.tag)：\(format) · \(stats.packets) 包，全是静音（峰值 \(peak)）")
            lines.append(source.kind == .microphone ? "麦克风连通，但没有听到声音；对着它说几句再试。" : "采集连通，但 \(source.displayName) 这几秒没有出声；播放内容后再试。")
            return Report(lines: lines, advice: nil, ok: true, outcome: .silent)
        }
        lines.append("\(source.tag)：\(format) · \(stats.packets) 包，其中 \(stats.audible) 包有声音，峰值 \(peak) · 正常")
        return Report(lines: lines, advice: nil, ok: true)
    }

    static func advice(for failure: CaptureFailure, source: AudioSourceDescriptor) -> RecoveryAdvice? {
        switch failure.kind {
        case .permissionDenied:
            return source.kind == .microphone
                ? RecoveryAdvice(title: "需要麦克风权限", detail: failure.message, action: .openMicrophoneSettings)
                : RecoveryAdvice(title: "需要系统音频录制权限", detail: failure.message, action: .openAudioCaptureSettings)
        case .deviceUnavailable:
            return source.kind == .microphone
                ? RecoveryAdvice(title: "麦克风不可用", detail: failure.message, action: .reselectMicrophone)
                : RecoveryAdvice(title: "来源不可用", detail: failure.message, action: nil)
        case .sourceNotFound:
            return RecoveryAdvice(title: "找不到来源", detail: failure.message, action: nil)
        case .systemError, .unsupported:
            return RecoveryAdvice(title: "采集失败", detail: failure.message, action: nil)
        }
    }
}
