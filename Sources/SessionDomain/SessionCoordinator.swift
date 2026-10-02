import Foundation
import AudioDomain
import CaptionDomain
import ProviderAdapters

public struct LaneFactories: Sendable {
    public var makeCapture: @Sendable (LaneConfiguration) throws -> any AudioCapture
    public var makeProvider: @Sendable (LaneConfiguration) throws -> any TranslationProvider
    public var makeAdapter: @Sendable (LaneConfiguration) -> any AudioFormatAdapter

    public init(makeCapture: @escaping @Sendable (LaneConfiguration) throws -> any AudioCapture, makeProvider: @escaping @Sendable (LaneConfiguration) throws -> any TranslationProvider, makeAdapter: @escaping @Sendable (LaneConfiguration) -> any AudioFormatAdapter = { _ in ResamplingFormatAdapter() }) {
        self.makeCapture = makeCapture
        self.makeProvider = makeProvider
        self.makeAdapter = makeAdapter
    }
}

/// Session lifecycle: idle → preparing → connecting → running ↔ paused → draining → completed.
/// Applies lane outputs to the reducer and publishes rate-limited snapshots.
public actor SessionCoordinator {
    public nonisolated let sessionID: String
    private var state: SessionState = .idle
    private var reducer: CaptionReducer
    private var lanes: [LaneCoordinator] = []
    private var laneStatuses: [String: LaneStatus] = [:]
    private var laneOrder: [String] = []
    private var tasks: [Task<Void, Never>] = []
    private var startedAtHostNs: Int64?
    /// Fixed once the session reaches a terminal state; elapsed time stops here.
    private var endedAtHostNs: Int64?
    private var failure: String?
    private var detail: String?
    private var pendingPublish = false
    private var lastPublishNs: Int64 = 0
    public var publishIntervalNs: Int64 = 33_000_000

    private let snapshotContinuation: AsyncStream<SessionSnapshot>.Continuation
    public nonisolated let snapshots: AsyncStream<SessionSnapshot>

    public init(sessionID: String = UUID().uuidString) {
        self.sessionID = sessionID
        self.reducer = CaptionReducer(sessionID: sessionID)
        var cont: AsyncStream<SessionSnapshot>.Continuation!
        self.snapshots = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.snapshotContinuation = cont
    }

    public var currentSnapshot: SessionSnapshot { makeSnapshot() }

    // MARK: - Commands

    public func reviewVocabularyCandidate(segmentID: String, revision: Int,
                                          candidate: VocabularyCorrectionCandidate, confirm: Bool) -> Bool {
        guard reducer.reviewVocabularyCandidate(segmentID: segmentID, revision: revision, candidate: candidate, confirm: confirm) else { return false }
        publishNow()
        return true
    }

    public func start(lanes configs: [LaneConfiguration], factories: LaneFactories) async {
        guard state == .idle || state == .completed || state == .failed else { return }
        state = .preparing
        detail = "正在检查权限与引擎"
        failure = nil
        reducer = CaptionReducer(sessionID: sessionID)
        laneStatuses = [:]
        laneOrder = configs.map(\.id)
        publishNow()
        let anchor = MonotonicClock.nowNs()
        startedAtHostNs = anchor
        endedAtHostNs = nil
        var built: [LaneCoordinator] = []
        for cfg in configs {
            do {
                let capture = try factories.makeCapture(cfg)
                let provider = try factories.makeProvider(cfg)
                let lane = LaneCoordinator(sessionID: sessionID, configuration: cfg, capture: capture, provider: provider, adapter: factories.makeAdapter(cfg), sessionAnchorNs: anchor)
                built.append(lane)
            } catch {
                state = .failed
                failure = "无法创建通道 \(cfg.source.tag)：\(error)"
                endedAtHostNs = MonotonicClock.nowNs()
                publishNow()
                return
            }
        }
        lanes = built
        state = .connecting
        detail = "正在连接引擎"
        publishNow()
        for lane in lanes {
            tasks.append(Task { [weak self] in
                for await out in lane.output {
                    await self?.handle(out, from: lane.id)
                }
            })
        }
        var anyStarted = false
        for lane in lanes {
            guard acceptsSessionCommands else { return }
            do {
                try await lane.start()
                guard acceptsSessionCommands else { await lane.stop(); return }
                anyStarted = true
            } catch {
                guard acceptsSessionCommands else { return }
                let msg = "\(lane.configuration.source.tag) 启动失败：\(error)"
                failure = msg
                if var s = laneStatuses[lane.id] {
                    s.lastError = msg
                    s.capture.state = .failed
                    laneStatuses[lane.id] = s
                } else {
                    var s = await lane.status
                    s.lastError = msg
                    s.capture.state = .failed
                    laneStatuses[lane.id] = s
                }
            }
        }
        guard acceptsSessionCommands else { return }
        if anyStarted {
            if state != .paused { state = lanes.count > 1 && failure != nil ? .degraded : .running }
            detail = nil
        } else {
            state = .failed
            endedAtHostNs = MonotonicClock.nowNs()
        }
        publishNow()
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.tick()
            }
        }
    }

    private var tickTask: Task<Void, Never>?
    private var acceptsSessionCommands: Bool { state.isActive && state != .draining && state != .stopping }

    public func pause() async {
        guard state == .running || state == .degraded || state == .reconnecting || state == .connecting || state == .preparing else { return }
        for lane in lanes { await lane.pause() }
        guard acceptsSessionCommands else { return }
        state = .paused
        publishNow()
    }

    public func resume() async {
        guard state == .paused else { return }
        for lane in lanes { await lane.resume() }
        guard acceptsSessionCommands else { return }
        state = .running
        publishNow()
    }

    /// Automatic wind-down when every lane has stopped producing; keeps the reason visible.
    private func finish(reason: String) async {
        guard state == .stopping else { return }
        state = .draining
        await drainAndComplete(unfinishedReason: "引擎结束时这句没有定稿")
        failure = reason
        detail = reason
        publishNow()
    }

    public func stop() async {
        guard state.isActive, state != .draining, state != .stopping else { return }
        state = .draining
        detail = "正在收尾最后一句"
        publishNow()
        await drainAndComplete(unfinishedReason: "停止时这句没有定稿")
        publishNow()
    }

    private func drainAndComplete(unfinishedReason: String) async {
        for lane in lanes {
            await lane.stop()
            // The lane's output stream finishes after stop; read its final status directly so the
            // completed snapshot never races the consumer task.
            laneStatuses[lane.id] = await lane.status
        }
        // Whatever the providers left open is frozen and marked, never left as "识别中".
        _ = reducer.freezeOpenSegments(reason: unfinishedReason)
        state = .completed
        endedAtHostNs = MonotonicClock.nowNs()
        detail = nil
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - Lane outputs

    private func handle(_ output: LaneOutput, from laneID: String) {
        switch output {
        case .caption(let event):
            let effects = reducer.apply(event)
            if !effects.isEmpty { schedulePublish() }
        case .status(let status):
            // After completion the lane's final status was read synchronously in stop().
            if state == .completed, let existing = laneStatuses[laneID], existing.capture.state == .stopped { return }
            laneStatuses[laneID] = status
            recomputeState()
            schedulePublish()
        case .failed(let message):
            failure = message
            recomputeState()
            schedulePublish()
        }
    }

    /// The lane can never produce captions again in this session.
    private func isDown(_ s: LaneStatus) -> Bool {
        s.providerLink == .failed || s.providerLink == .closed || s.capture.state == .failed || s.capture.state == .permissionRequired
    }

    /// The lane is not producing right now but may recover on its own (target application quit
    /// and the tap is waiting for it to relaunch, device change being rebuilt).
    private func isImpaired(_ s: LaneStatus) -> Bool {
        isDown(s) || s.capture.state == .sourceUnavailable || s.capture.state == .recovering
    }

    private func recomputeState() {
        guard state.isActive, state != .draining, state != .stopping, state != .preparing else { return }
        let statuses = laneOrder.compactMap { laneStatuses[$0] }
        guard !statuses.isEmpty else { return }
        let failed = statuses.filter(isDown)
        if failed.count == statuses.count {
            // Nothing left that can produce captions: stop capturing rather than look alive.
            // This applies while paused too; "已暂停 · 可继续" with a dead engine is a lie.
            state = .stopping
            let reason = failure ?? failed.compactMap(\.lastError).first ?? "所有通道已停止"
            failure = reason
            Task { [weak self] in await self?.finish(reason: reason) }
            return
        }
        guard state != .paused else { return }
        let impaired = statuses.filter(isImpaired)
        let reconnecting = statuses.contains { $0.providerLink == .reconnecting }
        if !impaired.isEmpty {
            state = .degraded
        } else if reconnecting {
            state = .reconnecting
        } else if state == .reconnecting || state == .degraded || state == .connecting {
            state = .running
        }
    }

    private func tick() {
        // Elapsed time and stale-audio detection are time driven, not event driven.
        for (id, var s) in laneStatuses {
            if s.capture.state == .capturing, let last = s.capture.lastAudioNs, let start = startedAtHostNs {
                let now = MonotonicClock.nowNs() - start
                if now - last > 3_000_000_000 {
                    s.capture.state = .sourceIdle
                    laneStatuses[id] = s
                }
            }
        }
        schedulePublish()
    }

    // MARK: - Publish

    private func schedulePublish() {
        let now = MonotonicClock.nowNs()
        if now - lastPublishNs >= publishIntervalNs {
            publishNow()
        } else if !pendingPublish {
            pendingPublish = true
            let delay = publishIntervalNs - (now - lastPublishNs)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(delay, 1_000_000)))
                await self?.flushPending()
            }
        }
    }

    private func flushPending() {
        pendingPublish = false
        publishNow()
    }

    private func publishNow() {
        lastPublishNs = MonotonicClock.nowNs()
        snapshotContinuation.yield(makeSnapshot())
    }

    private func makeSnapshot() -> SessionSnapshot {
        let elapsed = startedAtHostNs.map { (endedAtHostNs ?? MonotonicClock.nowNs()) - $0 } ?? 0
        return SessionSnapshot(
            sessionID: sessionID,
            state: state,
            captions: reducer.snapshot,
            lanes: laneOrder.compactMap { laneStatuses[$0] },
            startedAtHostNs: startedAtHostNs,
            elapsedNs: elapsed,
            failure: failure,
            detail: detail
        )
    }
}
