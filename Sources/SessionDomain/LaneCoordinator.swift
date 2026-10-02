import Foundation
import AudioDomain
import CaptionDomain
import ProviderAdapters

public enum LaneOutput: Sendable {
    case caption(CaptionEvent)
    case status(LaneStatus)
    case failed(String)
}

/// Owns one physical source: capture → bounded queue → provider, plus health and recovery.
/// Nothing here runs on the audio callback; the capture object hands us packets on a worker.
///
/// Failure policy: a provider error is classified once (`ProviderError.classification`) and
/// drives the link state. Retryable → reconnect with backoff up to `maxReconnectAttempts`;
/// anything else → the lane fails, stops uploading, and reports it. Audio that could not be
/// sent is recorded as one coalesced `uploadFailed` gap, never dropped silently.
public actor LaneCoordinator {
    public nonisolated let id: String
    public let configuration: LaneConfiguration
    private let sessionID: String
    private let capture: any AudioCapture
    private let provider: any TranslationProvider
    private let adapter: any AudioFormatAdapter
    private let queue: BoundedAudioQueue
    private let sessionAnchorNs: Int64

    private var providerEpoch: UInt64 = 0
    private var captureEpoch: UInt64 = 0
    private var health: CaptureHealth
    private var link: ProviderLinkState = .idle
    private var reconnectAttempts = 0
    private var lastError: String?
    private var uploading = false
    private var pauseRequested = false
    private var captureStarted = false
    private var pausedSinceNs: Int64?
    private var sentWatermarkNs: Int64 = 0
    private var capturedWatermarkNs: Int64 = 0
    private var captureDroppedNs: Int64 = 0
    private var laneDroppedNs: Int64 = 0
    private var tasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var closedContinuation: CheckedContinuation<Void, Never>?
    /// The provider reported `.closed` for the current session (solicited or not).
    private var closed = false
    private var stopping = false
    private var stopped = false
    /// Contiguous interval of captured audio the provider has not accepted (start, end).
    private var unsent: (start: Int64, end: Int64, epoch: UInt64)?

    private let outputContinuation: AsyncStream<LaneOutput>.Continuation
    public nonisolated let output: AsyncStream<LaneOutput>

    public var maxReconnectAttempts = 5
    /// Audio older than this without energy counts as "source idle" in the merged health.
    public var silenceIdleNs: Int64 = 3_000_000_000

    public init(sessionID: String, configuration: LaneConfiguration, capture: any AudioCapture, provider: any TranslationProvider, adapter: any AudioFormatAdapter = ResamplingFormatAdapter(), sessionAnchorNs: Int64, queueCapacityNs: Int64 = 2_000_000_000) {
        self.id = configuration.id
        self.sessionID = sessionID
        self.configuration = configuration
        self.capture = capture
        self.provider = provider
        self.adapter = adapter
        self.sessionAnchorNs = sessionAnchorNs
        self.queue = BoundedAudioQueue(capacityNs: queueCapacityNs)
        self.health = CaptureHealth(laneID: configuration.id)
        var cont: AsyncStream<LaneOutput>.Continuation!
        self.output = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.outputContinuation = cont
    }

    // MARK: - Lifecycle

    public func start() async throws {
        try await checkStartupNotStopped()
        try await capture.prepare(configuration.source)
        try await checkStartupNotStopped()
        link = .connecting
        publishStatus()
        providerEpoch = 1
        try await provider.open(ProviderSessionConfiguration(
            sessionID: sessionID,
            laneID: id,
            providerEpoch: providerEpoch,
            sourceLanguage: configuration.sourceLanguage,
            targetLanguage: configuration.targetLanguage,
            sourceKind: configuration.source.kind
        ))
        try await checkStartupNotStopped()
        provider.noteSessionTime(ns: MonotonicClock.nowNs() - sessionAnchorNs)
        tasks.append(Task { [weak self] in await self?.consumeProviderEvents() })
        tasks.append(Task { [weak self] in await self?.consumeCaptureEvents() })
        try await capture.start()
        try await checkStartupNotStopped()
        captureStarted = true
        uploading = !pauseRequested
        if pauseRequested { provider.setPaused(true) }
        publishStatus()
    }

    /// An asynchronous prepare/open/start may finish after stop. Release anything it created
    /// late instead of reviving a lane whose overlay was already closed.
    private func checkStartupNotStopped() async throws {
        guard !stopping && !stopped else {
            await capture.stop()
            await provider.cancel()
            throw CancellationError()
        }
    }

    public func pause() {
        guard !pauseRequested, !stopping, !stopped else { return }
        pauseRequested = true
        uploading = false
        pausedSinceNs = MonotonicClock.nowNs() - sessionAnchorNs
        _ = queue.drain()
        provider.setPaused(true)
        emitLaneState("paused")
        publishStatus()
    }

    public func resume() {
        guard pauseRequested, !stopping, !stopped else { return }
        pauseRequested = false
        uploading = captureStarted
        if let since = pausedSinceNs {
            let now = MonotonicClock.nowNs() - sessionAnchorNs
            emitGap(AudioGap(laneID: id, captureEpoch: captureEpoch, startNs: since, endNs: now, reason: .paused))
        }
        pausedSinceNs = nil
        provider.setPaused(false)
        emitLaneState("running")
        publishStatus()
    }

    /// Stop capture, ask the provider to flush, wait (bounded) for its close, then release.
    /// Idempotent. A `.closed` that already arrived (even before this call) is honored
    /// immediately; the wait is only installed when no close has been seen yet.
    public func stop(drainTimeoutNs: UInt64 = 3_000_000_000) async {
        guard !stopped else { return }
        stopped = true
        stopping = true
        uploading = false
        reconnectTask?.cancel()
        reconnectTask = nil
        provider.setPaused(false)
        await capture.stop()
        if !captureStarted {
            // There is no captured tail to flush while startup is still pending.
            await provider.cancel()
            for task in tasks { task.cancel() }
            tasks.removeAll()
            link = .closed
            health.state = .stopped
            publishStatus()
            outputContinuation.finish()
            return
        }
        // Forward whatever was still queued before asking the provider to flush.
        for p in queue.drain() { await forward(p) }
        flushUnsentGap()
        if link != .failed {
            do {
                try await provider.finishInput()
                if !closed {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        // Runs synchronously on the actor: `closed` cannot change in between.
                        if closed {
                            c.resume()
                            return
                        }
                        closedContinuation = c
                        timeoutTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: drainTimeoutNs)
                            await self?.timeoutClose()
                        }
                    }
                    timeoutTask?.cancel()
                    timeoutTask = nil
                }
            } catch {
                lastError = "收尾失败：\(error)"
            }
        }
        await provider.cancel()
        for t in tasks { t.cancel() }
        tasks.removeAll()
        if link != .failed { link = .closed }
        health.state = .stopped
        publishStatus()
        outputContinuation.finish()
    }

    private func timeoutClose() {
        if let c = closedContinuation {
            closedContinuation = nil
            lastError = "收尾超时，尾段可能未完成"
            c.resume()
        }
    }

    // MARK: - Capture side

    private func consumeCaptureEvents() async {
        for await event in capture.events {
            if Task.isCancelled { return }
            switch event {
            case .started(let epoch, let format):
                captureEpoch = epoch
                health.captureEpoch = epoch
                health.format = format
                health.state = .waitingForAudio
                publishStatus()
            case .packet(let packet):
                capturedWatermarkNs = packet.sourceEndNs
                health.callbackCount &+= 1
                let e = packet.samples.energy()
                health.level = e.rms
                health.peak = e.peak
                if AudioLevel.isAudible(rms: e.rms) {
                    health.lastAudioNs = packet.sourceEndNs
                    if health.state == .waitingForAudio || health.state == .sourceIdle { health.state = .capturing }
                }
                if packet.discontinuityBefore {
                    // Capture layer already emitted the gap; mirror the epoch here.
                    captureEpoch = packet.captureEpoch
                }
                guard uploading else { continue }
                if let gap = queue.push(packet) {
                    emitGap(gap)
                }
                // Forward promptly; the queue only absorbs bursts.
                while let p = queue.pop() {
                    await forward(p)
                }
                let s = queue.stats
                health.queuedNs = s.queuedNs
                laneDroppedNs = s.droppedNs
                health.droppedNs = captureDroppedNs + laneDroppedNs
                publishStatusThrottled()
            case .gap(let gap):
                emitGap(gap)
            case .health(let h):
                health = merge(capture: h)
                publishStatus()
            case .stopped(let epoch):
                if !stopping {
                    health.state = .stopped
                    health.detail = "采集停止（代次 \(epoch)）"
                    publishStatus()
                }
            case .failed(let failure):
                health.state = failure.kind == .permissionDenied ? .permissionRequired : .failed
                health.detail = failure.message
                lastError = failure.message
                publishStatus()
                outputContinuation.yield(.failed(failure.message))
            }
        }
    }

    /// The capture layer reports structure (connected, callbacks arriving, target alive); only
    /// the lane knows whether those callbacks carried sound. "Capturing" therefore requires
    /// recent energy, and the last-audio time is never overwritten by a structural update.
    private func merge(capture h: CaptureHealth) -> CaptureHealth {
        var merged = h
        merged.level = health.level
        merged.peak = health.peak
        merged.callbackCount = max(h.callbackCount, health.callbackCount)
        merged.queuedNs = health.queuedNs
        captureDroppedNs = h.droppedNs
        merged.droppedNs = captureDroppedNs + laneDroppedNs
        merged.lastAudioNs = health.lastAudioNs
        let recentEnergy = health.lastAudioNs.map { capturedWatermarkNs - $0 <= silenceIdleNs } ?? false
        switch merged.state {
        case .capturing where !recentEnergy:
            if let last = health.lastAudioNs {
                merged.state = .sourceIdle
                merged.detail = h.detail ?? "有回调，但最近 \((capturedWatermarkNs - last) / 1_000_000_000) 秒是静音"
            } else {
                merged.state = .waitingForAudio
                merged.detail = h.detail ?? "有回调，尚无声音"
            }
        case .sourceIdle where recentEnergy:
            // The capture's coarse silence check disagrees with the lane's RMS; the lane decides.
            merged.state = .capturing
            merged.detail = nil
        default:
            break
        }
        return merged
    }

    private func forward(_ packet: AudioPacket) async {
        guard link == .connected else {
            noteUnsent(packet)
            return
        }
        let target = provider.capabilities.inputFormats.first ?? AudioFormatDescriptor(sampleRate: packet.format.sampleRate, channelCount: 1)
        let converted = adapter.convert(packet, to: target)
        do {
            try await provider.push(converted)
            sentWatermarkNs = packet.sourceEndNs
            flushUnsentGap()
        } catch let error as ProviderError {
            noteUnsent(packet)
            handleProviderFailure(error, epoch: providerEpoch, context: "上传失败")
        } catch {
            noteUnsent(packet)
            handleProviderFailure(ProviderError(.retryable, "\(error)"), epoch: providerEpoch, context: "上传失败")
        }
    }

    private func noteUnsent(_ packet: AudioPacket) {
        if var u = unsent, u.epoch == packet.captureEpoch {
            u.end = max(u.end, packet.sourceEndNs)
            unsent = u
        } else {
            flushUnsentGap()
            unsent = (packet.sourceStartNs, packet.sourceEndNs, packet.captureEpoch)
        }
    }

    private func flushUnsentGap() {
        guard let u = unsent else { return }
        unsent = nil
        emitGap(AudioGap(laneID: id, captureEpoch: u.epoch, startNs: u.start, endNs: u.end, reason: .uploadFailed))
    }

    // MARK: - Provider side

    private func consumeProviderEvents() async {
        for await event in provider.events {
            if Task.isCancelled { return }
            switch event {
            case .opened(let epoch):
                providerEpoch = epoch
                link = .connected
                reconnectAttempts = 0
                flushUnsentGap()
                emitLaneState("running")
                publishStatus()
            case .caption(let caption):
                outputContinuation.yield(.caption(caption))
            case .disconnected(let epoch, let error):
                handleProviderFailure(error, epoch: epoch, context: "连接中断")
            case .closed:
                closed = true
                link = .closed
                if let c = closedContinuation {
                    closedContinuation = nil
                    c.resume()
                } else if !stopping {
                    // Unsolicited close (script finished, session limit reached without resume):
                    // say so instead of sitting in "listening" with a live level and no captions.
                    uploading = false
                    lastError = "引擎已结束会话（\(provider.capabilities.displayName)）"
                    emitLaneState("stopped")
                    publishStatus()
                    outputContinuation.yield(.failed(lastError!))
                    continue
                }
                publishStatus()
            case .usage:
                break
            }
        }
    }

    /// One place decides what a provider error means for the lane.
    private func handleProviderFailure(_ error: ProviderError, epoch: UInt64, context: String) {
        lastError = "\(context)：\(error.message)"
        guard !stopping else { return }
        switch error.classification {
        case .retryable:
            guard link != .reconnecting, link != .failed else { return }
            link = .reconnecting
            reconnectAttempts += 1
            emitLaneState("reconnecting")
            publishStatus()
            if !provider.reconnectsInternally {
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in await self?.reconnectLoop(after: epoch) }
            }
        case .userFixable, .unsupported, .permanent:
            failLane(reason: lastError!)
        }
    }

    private func failLane(reason: String) {
        guard link != .failed else { return }
        link = .failed
        uploading = false
        lastError = reason
        flushUnsentGap()
        emitLaneState("failed")
        publishStatus()
        outputContinuation.yield(.failed(reason))
    }

    /// Cancellable retry loop. Every real attempt is counted before it is made, so a provider
    /// whose `open` keeps throwing cannot loop past the limit.
    private func reconnectLoop(after epoch: UInt64) async {
        var nextEpoch = epoch
        while !stopping, !Task.isCancelled {
            if reconnectAttempts > maxReconnectAttempts {
                failLane(reason: "重连 \(maxReconnectAttempts) 次失败，已停止")
                return
            }
            // Exponential backoff with jitter, capped at 8 s.
            let base = min(8.0, pow(2.0, Double(max(0, reconnectAttempts - 1))) * 0.5)
            let jitter = Double.random(in: 0...0.3)
            try? await Task.sleep(nanoseconds: UInt64((base + jitter) * 1_000_000_000))
            if stopping || Task.isCancelled { return }
            nextEpoch += 1
            providerEpoch = nextEpoch
            do {
                try await provider.open(ProviderSessionConfiguration(
                    sessionID: sessionID, laneID: id, providerEpoch: providerEpoch,
                    sourceLanguage: configuration.sourceLanguage, targetLanguage: configuration.targetLanguage,
                    sourceKind: configuration.source.kind))
                return  // `.opened` resets the counter and the link state.
            } catch let error as ProviderError where error.classification != .retryable {
                failLane(reason: "重连失败：\(error.message)")
                return
            } catch {
                lastError = "重连失败：\(error)"
                reconnectAttempts += 1
                publishStatus()
            }
        }
    }

    // MARK: - Emit

    private var lastStatusPublishNs: Int64 = 0

    private func publishStatusThrottled() {
        let now = MonotonicClock.nowNs()
        if now - lastStatusPublishNs > 33_000_000 {
            publishStatus()
        }
    }

    private func publishStatus() {
        lastStatusPublishNs = MonotonicClock.nowNs()
        outputContinuation.yield(.status(status))
    }

    public var status: LaneStatus {
        LaneStatus(
            id: id,
            configuration: configuration,
            capture: health,
            providerName: provider.capabilities.displayName,
            providerEpoch: providerEpoch,
            providerLink: link,
            reconnectAttempts: reconnectAttempts,
            lastError: lastError,
            // "Uploading" is only true while audio actually reaches a connected provider.
            isUploading: uploading && link == .connected,
            dataDestination: provider.capabilities.dataDestination,
            sentWatermarkNs: sentWatermarkNs,
            capturedWatermarkNs: capturedWatermarkNs,
            isLocal: provider.capabilities.isLocal
        )
    }

    private func emitGap(_ gap: AudioGap) {
        guard gap.endNs >= gap.startNs else { return }
        var ev = CaptionEvent(type: .laneGap, sessionID: sessionID, laneID: id, captureEpoch: gap.captureEpoch, providerEpoch: providerEpoch, eventID: "gap-\(gap.reason.rawValue)-\(gap.startNs)-\(gap.endNs)")
        ev.startNs = gap.startNs
        ev.endNs = gap.endNs
        ev.gapReason = gap.reason.rawValue
        outputContinuation.yield(.caption(ev))
    }

    private func emitLaneState(_ state: String) {
        var ev = CaptionEvent(type: .laneState, sessionID: sessionID, laneID: id, captureEpoch: captureEpoch, providerEpoch: providerEpoch, eventID: "state-\(state)-\(MonotonicClock.nowNs())")
        ev.laneState = state
        outputContinuation.yield(.caption(ev))
    }
}
