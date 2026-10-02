import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import AudioDomain
import LLObjCSupport

/// Microphone lane via AVAudioEngine. Permission is requested here, only when the user picked a
/// microphone. Device / format changes restart the same engine under a new capture epoch with an
/// explicit gap; restarts are debounced because tearing down an engine can itself post a change.
///
/// Format safety (B01): Bluetooth headsets switch sample rate when their microphone is engaged
/// (AirPods 48 kHz → 24 kHz), and the node's cached format can lag behind. The tap is installed
/// with the node's *current* output format, every AVFoundation call that can raise an
/// Objective-C exception is wrapped so it becomes a lane error instead of a process abort, and
/// the first start retries with a fresh engine while the route settles.
public final class MicrophoneCapture: AudioCapture, @unchecked Sendable {
    public let laneID: String
    public let events: AsyncStream<CaptureEvent>

    private let handoff: CaptureHandoff
    private let lock = NSLock()
    private let control = DispatchQueue(label: "LiveLearn.mic.control", qos: .userInitiated)
    private let sessionAnchorNs: Int64
    private var engine: AVAudioEngine?
    private var source: AudioSourceDescriptor?
    private var epoch: UInt64 = 0
    private var observer: NSObjectProtocol?
    private var running = false
    private var format: AudioFormatDescriptor?
    private var lastRestartNs: Int64 = 0
    private var pendingRestart = false
    private var consecutiveRestarts = 0
    private var mismatchReported = false

    /// How many times `start` re-creates the engine when the input format is still moving.
    public var startAttempts = 3

    public init(laneID: String, sessionAnchorNs: Int64) {
        self.laneID = laneID
        self.sessionAnchorNs = sessionAnchorNs
        var cont: AsyncStream<CaptureEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.handoff = CaptureHandoff(laneID: laneID, sessionAnchorNs: sessionAnchorNs, sampleRate: 48_000, continuation: cont)
    }

    private var sessionNowNs: Int64 { MonotonicClock.nowNs() - sessionAnchorNs }

    // MARK: - Permission

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - AudioCapture

    public func prepare(_ source: AudioSourceDescriptor) async throws {
        guard source.kind == .microphone else {
            throw CaptureFailure(kind: .unsupported, message: "MicrophoneCapture 只处理麦克风来源")
        }
        lock.withLock { self.source = source }
        switch Self.authorizationStatus {
        case .authorized:
            break
        case .notDetermined:
            // The consent dialog is up; tell the session what it is waiting for.
            handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .recovering, detail: "正在等待系统权限确认：请在弹出的对话框中允许 LiveLearn 使用麦克风")))
            let ok = await Self.requestAccess()
            if !ok { throw CaptureFailure(kind: .permissionDenied, message: "麦克风权限被拒绝，请在 系统设置 › 隐私与安全性 › 麦克风 中允许 LiveLearn") }
        case .denied, .restricted:
            throw CaptureFailure(kind: .permissionDenied, message: "麦克风权限未授予，请在 系统设置 › 隐私与安全性 › 麦克风 中允许 LiveLearn")
        @unknown default:
            throw CaptureFailure(kind: .permissionDenied, message: "麦克风权限状态未知")
        }
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                var lastError: Error?
                for attempt in 1...max(1, startAttempts) {
                    do {
                        let engine = AVAudioEngine()
                        lock.withLock { self.engine = engine }
                        try selectDevice(on: engine)
                        // Earlier attempts wait for hardware and node formats to agree; the last
                        // one proceeds regardless (the tap adopts the node format, and a stale
                        // format is caught by the callback check and rebuilt).
                        try installAndStart(engine, reason: nil, strict: attempt < max(1, startAttempts))
                        lock.withLock { running = true }
                        handoff.startWorker()
                        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                            guard let self else { return }
                            self.control.async { self.handleConfigurationChange() }
                        }
                        c.resume()
                        return
                    } catch let failure as CaptureFailure {
                        lastError = failure
                        lock.withLock { self.engine = nil }
                        // Only a format/route problem is worth retrying; permission or a missing
                        // device will not change in 300 ms.
                        guard failure.kind == .deviceUnavailable, failure.code == Self.formatRaceCode, attempt < startAttempts else { break }
                        usleep(300_000)
                    } catch {
                        lastError = error
                        lock.withLock { self.engine = nil }
                        break
                    }
                }
                c.resume(throwing: lastError ?? CaptureFailure(kind: .systemError, message: "麦克风启动失败"))
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            control.async { [self] in
                if let o = observer { NotificationCenter.default.removeObserver(o) }
                observer = nil
                let e = lock.withLock { () -> AVAudioEngine? in
                    running = false
                    let e = engine
                    engine = nil
                    return e
                }
                if let e {
                    e.inputNode.removeTap(onBus: 0)
                    e.stop()
                }
                handoff.stopWorker()
                handoff.yield(.stopped(epoch: epoch))
                c.resume()
            }
        }
    }

    // MARK: - Engine (control queue)

    /// Marker code for "the input format was not usable at this instant" (retryable at start).
    static let formatRaceCode: Int32 = -10_868  // kAudioUnitErr_FormatNotSupported

    private func selectDevice(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        guard let uid = lock.withLock({ source?.deviceUID }) else { return }  // follow the system default
        guard let device = AudioDeviceList.inputDevice(uid: uid) else {
            let name = lock.withLock { source?.displayName } ?? uid
            throw CaptureFailure(kind: .deviceUnavailable, message: "找不到所选麦克风「\(name)」，请重新选择设备")
        }
        guard let unit = input.audioUnit else {
            throw CaptureFailure(kind: .deviceUnavailable, message: "输入节点没有音频单元")
        }
        var deviceID = device.id
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
        if status != noErr {
            throw CaptureFailure(kind: .deviceUnavailable, message: "无法选择麦克风设备 \(device.name)", code: status)
        }
    }

    /// `strict`: refuse to tap while the hardware and node formats disagree (route mid-switch).
    private func installAndStart(_ engine: AVAudioEngine, reason: String?, strict: Bool = false) throws {
        let input = engine.inputNode
        // The tap must match the node's output format on this bus; read it right before installing.
        let nativeFormat = input.outputFormat(forBus: 0)
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw CaptureFailure(kind: .deviceUnavailable, message: "麦克风没有可用输入格式（可能没有输入设备）", code: hardwareFormat.sampleRate > 0 ? Self.formatRaceCode : nil)
        }
        if strict, hardwareFormat.sampleRate > 0, hardwareFormat.sampleRate != nativeFormat.sampleRate {
            // The route is mid-switch (Bluetooth profile change); let it settle rather than tap a stale graph.
            throw CaptureFailure(kind: .deviceUnavailable, message: "麦克风格式正在切换（硬件 \(Int(hardwareFormat.sampleRate)) Hz，节点 \(Int(nativeFormat.sampleRate)) Hz）", code: Self.formatRaceCode)
        }
        let descriptor = AudioFormatDescriptor(sampleRate: nativeFormat.sampleRate, channelCount: Int(nativeFormat.channelCount), sampleType: .float32, isInterleaved: nativeFormat.isInterleaved)
        epoch += 1
        handoff.beginEpoch(epoch, sampleRate: nativeFormat.sampleRate)
        lock.withLock {
            self.format = descriptor
            self.mismatchReported = false
        }
        let handoff = self.handoff
        let weakSelf = WeakBox(self)
        input.removeTap(onBus: 0)
        var installError: NSError?
        let installed = LLCatchObjCException({
            // `format: nil` adopts the bus format, so the tap can never disagree with the node.
            input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, when in
                // Copy out immediately; the buffer is not ours to keep.
                let frames = Int(buffer.frameLength)
                guard frames > 0, let data = buffer.floatChannelData else { return }
                let bufferChannels = Int(buffer.format.channelCount)
                if buffer.format.sampleRate != descriptor.sampleRate || bufferChannels != descriptor.channelCount {
                    // The graph changed under us; rebuild under a new epoch rather than mis-stamp audio.
                    weakSelf.value?.noteFormatMismatch(buffer.format)
                    return
                }
                var channels: [[Float]] = []
                channels.reserveCapacity(bufferChannels)
                // While the app reads a translation aloud the microphone carries silence, not
                // nothing: the lane's clock stays continuous.
                let muted = MicrophoneGate.shared.isMuted
                for c in 0..<bufferChannels {
                    channels.append(muted ? Array(repeating: 0, count: frames) : Array(UnsafeBufferPointer(start: data[c], count: frames)))
                }
                handoff.deliver(channels: channels, format: descriptor, hostTime: when.isHostTimeValid ? when.hostTime : nil)
            }
        }, &installError)
        guard installed else {
            input.removeTap(onBus: 0)
            throw CaptureFailure(kind: .deviceUnavailable, message: "无法在麦克风上安装采集（\(installError?.localizedDescription ?? "格式不匹配")）", code: Self.formatRaceCode)
        }
        var prepareError: NSError?
        guard LLCatchObjCException({ engine.prepare() }, &prepareError) else {
            input.removeTap(onBus: 0)
            throw CaptureFailure(kind: .deviceUnavailable, message: "AVAudioEngine 准备失败：\(prepareError?.localizedDescription ?? "")", code: Self.formatRaceCode)
        }
        var startFailure: Error?
        var startException: NSError?
        let started = LLCatchObjCException({
            do { try engine.start() } catch { startFailure = error }
        }, &startException)
        if !started || startFailure != nil {
            input.removeTap(onBus: 0)
            let reasonText = startException?.localizedDescription ?? startFailure?.localizedDescription ?? "未知"
            throw CaptureFailure(kind: .systemError, message: "AVAudioEngine 启动失败：\(reasonText)", code: started ? nil : Self.formatRaceCode)
        }
        lastRestartNs = MonotonicClock.nowNs()
        handoff.yield(.started(epoch: epoch, format: descriptor))
        handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .waitingForAudio, format: descriptor, detail: reason)))
    }

    /// Audio thread: the tap delivered a buffer whose format differs from the one this epoch was
    /// stamped with. Report once and let the configuration-change path rebuild.
    private func noteFormatMismatch(_ actual: AVAudioFormat) {
        let first: Bool = lock.withLock {
            if mismatchReported { return false }
            mismatchReported = true
            return true
        }
        guard first else { return }
        control.async { [weak self] in
            guard let self else { return }
            self.handoff.yield(.health(CaptureHealth(laneID: self.laneID, captureEpoch: self.epoch, state: .recovering, format: self.format, detail: "麦克风格式变为 \(Int(actual.sampleRate)) Hz / \(actual.channelCount)ch，正在重建")))
            self.handleConfigurationChange(force: true)
        }
    }

    /// The engine is stopped by the system when its configuration changes. Restart it in place,
    /// debounced: changes arriving within 400 ms of our own restart are coalesced into one.
    private func handleConfigurationChange(force: Bool = false) {
        guard lock.withLock({ running }), let engine = lock.withLock({ self.engine }) else { return }
        let now = MonotonicClock.nowNs()
        let sinceRestart = now - lastRestartNs
        if sinceRestart < 400_000_000 {
            if !pendingRestart {
                pendingRestart = true
                control.asyncAfter(deadline: .now() + .milliseconds(450)) { [weak self] in
                    self?.pendingRestart = false
                    self?.handleConfigurationChange(force: force)
                }
            }
            return
        }
        if engine.isRunning && !force {
            // Spurious notification: the engine kept running, keep the epoch.
            return
        }
        consecutiveRestarts = sinceRestart < 2_000_000_000 ? consecutiveRestarts + 1 : 0
        if consecutiveRestarts > 5 {
            handoff.yield(.failed(CaptureFailure(kind: .deviceUnavailable, message: "输入设备持续变化，已停止重建（6 次）")))
            lock.withLock { running = false }
            return
        }
        let before = sessionNowNs
        handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .recovering, format: format, detail: "输入设备或格式发生变化，正在重建")))
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        do {
            try installAndStart(engine, reason: "设备变化后已恢复")
            handoff.yield(.gap(AudioGap(laneID: laneID, captureEpoch: epoch, startNs: before, endNs: sessionNowNs, reason: .deviceChange)))
        } catch {
            handoff.yield(.failed(CaptureFailure(kind: .deviceUnavailable, message: "设备变化后无法恢复：\(error)")))
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}
