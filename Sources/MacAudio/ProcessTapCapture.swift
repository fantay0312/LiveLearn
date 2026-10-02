import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import AudioDomain

/// Application / system audio via Core Audio process taps (macOS 14.2+).
///
/// Lifecycle (doc §6.2): resolve identity → tap description → tap → private aggregate device →
/// IOProc → start; stop in reverse. Every created object is tracked and released on any failure.
/// Membership changes (helper restarts) rebuild the tap under a new capture epoch; the target
/// exiting is reported, never widened to the whole system.
///
/// An application that is running but has no Core Audio process object yet (nothing played
/// since launch) is not an error: the capture enters a waiting state, listens for the process
/// list to change, and builds the tap the moment an audio process of that app appears.
public final class ProcessTapCapture: AudioCapture, @unchecked Sendable {
    public let laneID: String
    public let events: AsyncStream<CaptureEvent>

    private let handoff: CaptureHandoff
    private let lock = NSLock()
    private let control = DispatchQueue(label: "LiveLearn.tap.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "LiveLearn.tap.io", qos: .userInteractive)
    private let sessionAnchorNs: Int64

    private var source: AudioSourceDescriptor?
    private var membership: ApplicationAudioMembership?
    private var resources = TapResources()
    private var epoch: UInt64 = 0
    private var running = false
    private var format: AudioFormatDescriptor?
    private var monitor: DispatchSourceTimer?
    /// Kept so the very same block (and queue) is passed to the remove call (R01).
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var lastCallbackNs: Int64 = 0
    private var lastEnergyNs: Int64 = 0
    private var state: CaptureState = .idle

    private struct TapResources {
        var tapID: AudioObjectID = 0
        var aggregateID: AudioObjectID = 0
        var ioProcID: AudioDeviceIOProcID?
        var started = false
        var tapUUID: UUID?
    }

    public init(laneID: String, sessionAnchorNs: Int64) {
        self.laneID = laneID
        self.sessionAnchorNs = sessionAnchorNs
        var cont: AsyncStream<CaptureEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.handoff = CaptureHandoff(laneID: laneID, sessionAnchorNs: sessionAnchorNs, sampleRate: 48_000, continuation: cont)
    }

    private var sessionNowNs: Int64 { MonotonicClock.nowNs() - sessionAnchorNs }

    // MARK: - AudioCapture

    public func prepare(_ source: AudioSourceDescriptor) async throws {
        switch source.kind {
        case .application:
            let bids = source.allBundleIdentifiers
            guard !bids.isEmpty else {
                throw CaptureFailure(kind: .sourceNotFound, message: "没有应用标识")
            }
            let m = ApplicationAudioIdentityResolver.resolve(bundleIdentifiers: bids)
            guard m.isRunning else {
                throw CaptureFailure(kind: .sourceNotFound, message: bids.count > 1 ? "\(source.displayName) 都没有在运行" : "\(source.displayName) 没有在运行")
            }
            lock.withLock {
                self.source = source
                self.membership = m
            }
        case .system:
            lock.withLock {
                self.source = source
                self.membership = nil
            }
        case .microphone:
            throw CaptureFailure(kind: .unsupported, message: "ProcessTapCapture 不处理麦克风")
        }
    }

    public func start() async throws {
        // Creating the first tap blocks inside Core Audio while macOS shows the "system audio
        // recording" consent dialog. If the call has not returned after a moment, say so, so
        // the session does not sit in "正在连接" with no explanation.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.lock.withLock({ !self.running && self.resources.tapID == 0 }) else { return }
            self.handoff.yield(.health(CaptureHealth(laneID: self.laneID, captureEpoch: self.epoch, state: .recovering, detail: "正在等待系统权限确认：请在弹出的对话框中允许 LiveLearn 录制系统音频（系统设置 › 隐私与安全性 › 录屏与系统录音）")))
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5, execute: watchdog)
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                do {
                    let built = try buildAndStart(newEpoch: true)
                    lock.withLock { running = true }
                    handoff.startWorker()
                    installMonitors()
                    if !built {
                        let name = lock.withLock { source?.displayName } ?? "目标应用"
                        lock.withLock { state = .waitingForAudio }
                        handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .waitingForAudio, detail: "\(name) 还没有开始播放；等它发声后会自动开始采集")))
                    }
                    c.resume()
                } catch {
                    teardown()
                    c.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            control.async { [self] in
                lock.withLock { running = false }
                removeMonitors()
                teardown()
                handoff.stopWorker()
                handoff.yield(.stopped(epoch: epoch))
                c.resume()
            }
        }
    }

    // MARK: - Build / teardown (control queue)

    /// Returns false when the application is running but has no audio process yet (waiting mode).
    @discardableResult
    private func buildAndStart(newEpoch: Bool) throws -> Bool {
        let (source, membership) = lock.withLock { (self.source, self.membership) }
        guard let source else { throw CaptureFailure(kind: .sourceNotFound, message: "未选择来源") }

        let description: CATapDescription
        switch source.kind {
        case .application:
            guard let m = membership, m.isRunning else {
                throw CaptureFailure(kind: .sourceNotFound, message: "\(source.displayName) 没有在运行")
            }
            guard !m.memberObjectIDs.isEmpty else {
                // Running, but Core Audio has no process object for it yet: wait, do not fail.
                return false
            }
            description = CATapDescription(stereoMixdownOfProcesses: m.memberObjectIDs)
        case .system:
            let own = AudioProcessRegistry.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        case .microphone:
            throw CaptureFailure(kind: .unsupported, message: "不支持")
        }
        description.uuid = UUID()
        description.name = "LiveLearn Tap \(laneID)"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var res = TapResources()
        res.tapUUID = description.uuid
        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != 0 else {
            throw CaptureFailure(kind: tapStatus == kAudioHardwareIllegalOperationError ? .permissionDenied : .systemError,
                                 message: "创建 Process Tap 失败 \(fourCC(tapStatus))。若系统未授权“系统音频录制”，请在 系统设置 › 隐私与安全性 中允许 LiveLearn",
                                 code: tapStatus)
        }
        res.tapID = tapID

        let asbd: AudioStreamBasicDescription
        do {
            asbd = try CoreAudioProperty.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .systemError, message: "读取 Tap 格式失败：\(error)")
        }
        guard let layout = asbd.layout else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .unsupported, message: "Tap 的音频格式不受支持（formatID \(fourCC(OSStatus(bitPattern: asbd.mFormatID)))，\(asbd.mBitsPerChannel) bit，flags \(asbd.mFormatFlags)）")
        }
        let descriptor = layout.descriptor

        let outputUID: String
        do {
            outputUID = try AudioDeviceList.defaultSystemOutputUID()
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .systemError, message: "读取系统输出设备失败：\(error)")
        }
        let aggregateUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveLearn Capture \(laneID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard aggStatus == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .systemError, message: "创建私有聚合设备失败 \(fourCC(aggStatus))", code: aggStatus)
        }
        res.aggregateID = aggregateID

        if newEpoch { epoch += 1 }
        let currentEpoch = epoch
        handoff.beginEpoch(currentEpoch, sampleRate: asbd.mSampleRate)
        lock.withLock { self.format = descriptor }

        let handoff = self.handoff
        let weakSelf = WeakBox(self)
        var procID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, inInputTime, _, _ in
            let channels = copyChannels(from: inInputData, layout: layout)
            guard !channels.isEmpty else { return }
            let host = (inInputTime.pointee.mFlags.contains(.hostTimeValid)) ? inInputTime.pointee.mHostTime : nil
            weakSelf.value?.noteCallback(channels: channels)
            handoff.deliver(channels: channels, format: descriptor, hostTime: host)
        }
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .systemError, message: "注册 IOProc 失败 \(fourCC(procStatus))", code: procStatus)
        }
        res.ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureFailure(kind: .systemError, message: "启动聚合设备失败 \(fourCC(startStatus))", code: startStatus)
        }
        res.started = true
        lock.withLock {
            self.resources = res
            self.state = .waitingForAudio
            self.lastCallbackNs = 0
            self.lastEnergyNs = 0
        }
        handoff.yield(.started(epoch: currentEpoch, format: descriptor))
        let detail: String
        if source.kind == .application {
            let apps = source.allBundleIdentifiers.count
            detail = apps > 1
                ? "已连接到 \(source.displayName)（\(apps) 个应用，\(membership?.memberObjectIDs.count ?? 0) 个音频进程）"
                : "已连接到 \(source.displayName)（\(membership?.memberObjectIDs.count ?? 0) 个音频进程）"
        } else {
            detail = "已连接到系统混音（排除本应用）"
        }
        handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: currentEpoch, state: .waitingForAudio, format: descriptor, detail: detail)))
        return true
    }

    /// Reverse order of creation. Safe to call repeatedly.
    private func teardown() {
        let res = lock.withLock { () -> TapResources in
            let r = resources
            resources = TapResources()
            return r
        }
        if res.aggregateID != 0, let proc = res.ioProcID {
            if res.started { AudioDeviceStop(res.aggregateID, proc) }
            AudioDeviceDestroyIOProcID(res.aggregateID, proc)
        }
        if res.aggregateID != 0 { AudioHardwareDestroyAggregateDevice(res.aggregateID) }
        if res.tapID != 0 { AudioHardwareDestroyProcessTap(res.tapID) }
    }

    /// Audio thread: note that a callback happened and whether it carried any signal. A strided
    /// RMS against the shared `AudioLevel.audibleRMS` gate keeps this in step with the lane's
    /// exact measurement; the lane still has the final say when the two disagree.
    private func noteCallback(channels: [[Float]]) {
        let now = MonotonicClock.nowNs()
        let loud = channels.first.map { AudioLevel.isAudible(rms: AudioLevel.stridedRMS($0)) } ?? false
        lock.withLock {
            lastCallbackNs = now
            if loud { lastEnergyNs = now }
        }
    }

    // MARK: - Monitoring (doc §6.5): callbacks, process list, target liveness, energy.

    private func installMonitors() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.monitorTick() }
        timer.resume()
        monitor = timer
        var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.control.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkMembership() }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
        processListListener = status == noErr ? block : nil
    }

    private func removeMonitors() {
        monitor?.cancel()
        monitor = nil
        if let block = processListListener {
            var addr = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, control, block)
            if status != noErr {
                NSLog("LiveLearn: AudioObjectRemovePropertyListenerBlock failed \(fourCC(status))")
            }
            processListListener = nil
        }
    }

    private func monitorTick() {
        guard lock.withLock({ running }) else { return }
        checkMembership()
        let (source, membership, lastCb, lastEnergy, currentEpoch, fmt, hasTap) = lock.withLock { (self.source, self.membership, self.lastCallbackNs, self.lastEnergyNs, self.epoch, self.format, self.resources.tapID != 0) }
        let now = MonotonicClock.nowNs()
        let stats = handoff.queueStats
        var health = CaptureHealth(laneID: laneID, captureEpoch: currentEpoch, state: .capturing, callbackCount: handoff.callbackCount, format: fmt, queuedNs: stats.queuedNs, droppedNs: stats.droppedNs)
        let name = source?.displayName ?? "目标"
        if source?.kind == .application, let m = membership, !m.isRunning {
            health.state = .sourceUnavailable
            health.detail = "\(name) 已退出；重新打开后会自动继续"
        } else if !hasTap {
            health.state = .waitingForAudio
            health.detail = "\(name) 还没有音频进程；开始播放后会自动采集"
        } else if lastCb == 0 {
            health.state = .waitingForAudio
            health.detail = (membership?.anyOutputRunning ?? true) ? "已建立采集，尚未收到音频回调" : "\(name) 目前没有在播放声音"
        } else if now - lastCb > 3_000_000_000 {
            health.state = (membership?.anyOutputRunning ?? false) ? .recovering : .sourceIdle
            health.detail = health.state == .recovering ? "目标在发声，但采集回调已停止 \((now - lastCb) / 1_000_000_000) 秒" : "来源暂时没有声音"
        } else if lastEnergy == 0 {
            // Callbacks arrive but every buffer so far was silent: not "capturing" yet.
            health.state = .waitingForAudio
            health.detail = "有回调，尚无声音"
        } else if now - lastEnergy > 3_000_000_000 {
            health.state = .sourceIdle
            health.detail = "有回调，但最近 \((now - lastEnergy) / 1_000_000_000) 秒是静音"
        } else {
            health.state = .capturing
            health.detail = nil
        }
        // The lane coordinator merges level/energy; here we only report structural state.
        handoff.yield(.health(health))
    }

    private func checkMembership() {
        let (source, old) = lock.withLock { (self.source, self.membership) }
        guard let source, source.kind == .application else { return }
        let bids = source.allBundleIdentifiers
        guard !bids.isEmpty else { return }
        let fresh = ApplicationAudioIdentityResolver.resolve(bundleIdentifiers: bids)
        lock.withLock { self.membership = fresh }
        guard let old else { return }
        if !fresh.isRunning {
            if old.isRunning {
                // Target exited: release the tap, report, keep polling for relaunch. Never widen scope.
                teardown()
                handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .sourceUnavailable, format: format, detail: bids.count > 1 ? "\(source.displayName) 都已退出；重新打开后会自动继续" : "\(source.displayName) 已退出；重新打开后会自动继续")))
            }
            return
        }
        let membersChanged = fresh.memberObjectIDs != old.memberObjectIDs
        let hadTap = lock.withLock { resources.tapID != 0 }
        if membersChanged || !hadTap {
            guard !fresh.memberObjectIDs.isEmpty else { return }
            let before = sessionNowNs
            if hadTap { teardown() }
            do {
                let built = try buildAndStart(newEpoch: true)
                if built, hadTap {
                    // Only a rebuild interrupts audio; the first build after waiting does not.
                    handoff.yield(.gap(AudioGap(laneID: laneID, captureEpoch: epoch, startNs: before, endNs: sessionNowNs, reason: .sourceRestart)))
                }
            } catch {
                handoff.yield(.health(CaptureHealth(laneID: laneID, captureEpoch: epoch, state: .recovering, format: format, detail: "音频进程变化后重建失败：\(error)")))
            }
        }
    }
}

private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ v: T) { value = v }
}
