import Foundation
import Observation
import AppKit
import os
import AudioDomain
import CaptionDomain
import ProviderAdapters
import SessionDomain
import MacAudio
import LocalEngine
import SessionStorage
import CloudEngine
import EngineKit

private let modelLog = Logger(subsystem: "com.fantasy.livelearn", category: "model")

enum MainPage: String { case home, transcript, vocabulary }

/// One finished session as the sidebar lists it. The archive is the full transcript; `saved`
/// says whether it is on disk (auto-save, or the user saved it by hand).
struct SessionRecord: Identifiable, Equatable {
    var archive: SessionArchive
    var saved: Bool

    var id: String { archive.id }
    var title: String { archive.title }
    var startedAt: Date { archive.startedAt }
    var durationNs: Int64 { archive.durationNs }
    /// Sentences that reached a final state.
    var segmentCount: Int { archive.segmentCount }
    /// Sentences frozen before the engine finalized them (stop, reconnect, engine close).
    var incompleteCount: Int { archive.incompleteCount }
    var interrupted: Bool { archive.outcome == .interrupted }
}

/// Single source of truth for the UI. Receives rate-limited snapshots from the session actor,
/// smooths audio levels for the breath line, and owns the overlay panel and menu bar state.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    @ObservationIgnored lazy var dictation: DictationController = {
        let controller = DictationController(settings: settings.dictation)
        controller.targetFactory = { [weak self] in
            try DictationInputTarget.capture(allowCompatiblePaste: self?.settings.dictation.compatiblePaste ?? false)
        }
        controller.startBlocker = { [weak self] in
            guard let self else { return "应用正在退出。" }
            guard self.settings.modules.isEnabled(.dictation) else { return "请先在设置中安装并启用语音输入。" }
            return self.isActive || self.isCheckingSource || self.isReconfiguringSession
                ? "请先结束字幕会话或音源检查，再使用语音输入。" : nil
        }
        controller.configuration = { [weak self] in
            guard let self else { throw CancellationError() }
            guard let moduleDirectory = self.settings.modules.directory(.dictation) else {
                throw ProviderError(.userFixable, "请先安装并启用语音输入。")
            }
            let s = self.settings.dictation
            var bp = EngineBlueprint(settings: self.settings, credentials: self.credentials)
            let vocabulary = VocabularyMatcher.uniqueWords(bp.recognitionVocabulary + s.rules.map(\.target))
            bp.doubao.enableNonstream = true
            bp.doubao.hotWords = vocabulary
            bp.deepgram.keyterms = vocabulary
            bp.soniox.terms = vocabulary
            bp.geminiLive.vocabulary = vocabulary
            if !vocabulary.isEmpty { bp.realtime.prompt = "Vocabulary: \(vocabulary.joined(separator: ", "))." }
            let engine: any SpeechRecognizer
            if s.engine == DictationSettings.chatterflyEngine {
                engine = TypelessProcessRecognizer(config: TypelessProcessConfig(
                    executable: moduleDirectory.appendingPathComponent("Helpers/LiveLearnChatterfly"),
                    url: "wss://srss.chatterfly.tencent.com:443/srss/v1/speech/streaming_recognize", appKey: "", token: CredentialStore.load("dictation.chatterfly.token") ?? "",
                    deviceID: s.chatterflyDeviceID, appID: "", backend: .chatterfly))
            } else if s.engine == DictationSettings.optimizedEngine {
                engine = TypelessProcessRecognizer(config: TypelessProcessConfig(
                    executable: moduleDirectory.appendingPathComponent("Helpers/LiveLearnDictation"),
                    url: s.optimizedURL,
                    appKey: CredentialStore.load("dictation.optimized.appKey") ?? OptimizedDictationDefaults.bundled?.appKey ?? "",
                    token: CredentialStore.load("dictation.optimized.token") ?? "",
                    deviceID: s.optimizedDeviceID, appID: s.optimizedAppID))
            } else {
                guard let choice = RecognizerChoice(rawValue: s.engine) else { throw ProviderError(.userFixable, "请选择语音输入引擎。") }
                bp.recognizer = choice
                engine = try bp.makeRecognizer()
            }
            return DictationConfiguration(recognizer: engine,
                language: s.language == "auto" ? (engine.supportsAutoDetect ? nil : "zh-Hans") : s.language,
                vocabulary: vocabulary, replacements: s.rules,
                corrector: s.finalCorrection ? DictationCorrector(config: try self.dictationRefinementConfig()) : nil,
                microphoneID: self.selectedMicrophone?.uid, liveInsertion: s.liveInsertion)
        }
        return controller
    }()

    func dictationRefinementConfig() throws -> OpenAICompatibleConfig {
        let s = settings.dictation
        if s.refinementBaseURL.isEmpty && s.refinementModel.isEmpty { return blueprint.chat }
        return try DictationRefinementConfiguration.make(baseURL: s.refinementBaseURL, model: s.refinementModel,
                                                        key: CredentialStore.load("dictation.refinement"))
    }
    let localModelActivity = LocalModelActivity()
    let translationTestActivity = TranslationTestActivity()
    var mainPage: MainPage = .home
    private(set) var openHomeRequest = 0
    /// Raw session state as the coordinator publishes it, at packet rate (up to 30 Hz while
    /// audio flows). Model-internal: records, checkpoints and the derived properties below read
    /// it. Views read the fine-grained properties, each assigned only when its value changes, so
    /// a level tick or a callback counter never repaints the window.
    private(set) var snapshot: SessionSnapshot = .empty()
    /// The raw snapshot at most every 250 ms (and at once on a state or lane change), for the
    /// inspector and diagnostics: live counters without thirty repaints a second.
    private(set) var liveSnapshot: SessionSnapshot = .empty()
    private(set) var sessionState: SessionState = .idle
    private(set) var sessionID: String = "none"
    /// Lanes stripped of per-packet fields (level, peak, counters, queue, watermarks); changes on
    /// capture state, format, link, error or detail only.
    private(set) var lanes: [LaneStatus] = []
    /// Session time rounded down to whole seconds, in ns; one change per second for the clocks.
    private(set) var elapsedNs: Int64 = 0
    /// Captions after the stability preset has been applied. Every caption view reads this;
    /// `snapshot.captions` is the raw reducer output (diagnostics, records).
    private(set) var captions: CaptionSnapshot = CaptionSnapshot(sessionID: "none")
    /// Reading-column rows, tail placeholders and per-lane tails, rebuilt when `captions` or the
    /// lane set changes (a few times a second at most), never inside a view body.
    private(set) var transcriptRows: [TranscriptRow] = []
    private(set) var listeningRows: [ListeningRowModel] = []
    private(set) var laneTails: [String: LaneTail] = [:]
    private(set) var gapCount = 0
    /// Sentences carrying vocabulary correction candidates, counted once per caption change,
    /// so the vocabulary page's badge reads one Int instead of scanning every segment (which
    /// re-evaluated the whole mounted page on every partial while a session ran).
    private(set) var vocabularyCandidateCount = 0
    /// Top-bar status line (§8), recomputed per publish and assigned on change.
    private var rawStatusText = "未开始"
    var statusText: String {
        if sessionState == .completed, currentRecord?.saved == true, rawStatusText == "已结束 · 未保存" {
            return "已结束 · 已保存"
        }
        return rawStatusText
    }
    private(set) var lagText: String?
    /// The one thing to do about the session on screen, if it is stuck on something the user
    /// can fix (permission, missing device, missing model).
    private(set) var recoveryAdvice: RecoveryAdvice?
    /// Smoothed breath-line level per lane, quantized to 1/255 so silence stops the updates.
    private(set) var levels: [String: Float] = [:]
    /// The top bar's sound line per lane: the last two seconds of `levels` and a ripple phase
    /// that only advances with sound. Assigned only when it changed, so silence publishes nothing.
    private(set) var waves: [String: WaveTrace] = [:]
    /// 朗读译文: the system voice, the once-per-sentence gate, and the segments already read.
    @ObservationIgnored private let speech = SpeechOutput()
    @ObservationIgnored private var readAloud = ReadAloudGate()
    @ObservationIgnored private var spokenSegments: Set<String> = []
    /// Final sentences VoiceOver has been told about (§11: only finals, never a partial).
    @ObservationIgnored private var announcedSegments: Set<String> = []
    private(set) var applications: [RunningApplicationSummary] = []
    private(set) var microphones: [AudioInputDevice] = []
    private(set) var records: [SessionRecord] = []
    /// Set while the main window shows a past record instead of the live session.
    private(set) var viewingRecordID: String?
    /// Last message from the record store (save / delete / export outcome), shown in the sidebar.
    private(set) var storeMessage: String?
    /// The configured engine (both stages, with keys) as the session factory needs it; rebuilt
    /// whenever an engine setting or a stored key changes.
    private(set) var blueprint: EngineBlueprint
    @ObservationIgnored private var credentials: EngineCredentials
    @ObservationIgnored private var credentialsVersion: Int
    /// Readiness of the configured engine per language direction, keyed "source>target".
    private(set) var readiness: [String: EngineReadiness] = [:]
    private(set) var readinessRefreshing = false
    /// Result of the last "检查音源" run.
    private(set) var sourceCheckReport: SourceCheck.Report?
    private(set) var isCheckingSource = false
    private(set) var openSourceCheckRequest = 0
    @ObservationIgnored private var sourceCheckTask: Task<Void, Never>?
    /// Bumped when some part of the app wants Settings opened at `settings.requestedSettingsTab`.
    private(set) var openSettingsRequest = 0
    /// Bumped when the main window must be (re)opened and there is none to bring forward; the
    /// menu bar label, which is mounted for the app's whole life, answers with `openWindow`.
    private(set) var openMainWindowRequest = 0
    private(set) var openVocabularyWindowRequest = 0
    var translationVocabularyDraft: TranslationVocabularyDraft?

    func requestMainWindow() { openMainWindowRequest += 1 }
    /// Kept as the common entry point for older menu/settings callers. Vocabulary is now
    /// a main-window page; this never opens a separate vocabulary window.
    func requestVocabularyWindow() {
        mainPage = .vocabulary
        openVocabularyWindowRequest += 1
        if !mainWindowVisible { requestMainWindow() }
        if !isPreview {
            if let window = NSApp.windows.first(where: { $0.title == "LiveLearn" }) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func requestHome() {
        mainPage = .home
        // An explicit home click is meaningful even if the session is already idle.
        openHomeRequest += 1
    }

    func requestRecords() {
        mainPage = .transcript
        if !isActive, sessionState == .idle, let latest = records.first {
            showRecord(latest)
        }
    }

    /// Review is scoped to the session that supplied the visible sentence. Saved records
    /// commit to disk before changing the UI; a failed write leaves the candidate intact.
    func reviewVocabularyCandidate(sessionID: String, segmentID: String, revision: Int,
                                   candidate: VocabularyCorrectionCandidate, confirm: Bool) async -> String? {
        guard sessionID == snapshot.sessionID else { return "会话已切换，请重新查看候选。" }
        let currentVocabulary = settings.hotWords + GlossaryEntry.parse(settings.glossaryLines).map(\.source)
        if confirm, !currentVocabulary.contains(candidate.replacement) {
            return "目标词已从词库移除，请保留原文或重新添加词汇。"
        }
        if let coordinator, viewingRecordID == nil, snapshot.state.isActive {
            let accepted = await coordinator.reviewVocabularyCandidate(segmentID: segmentID, revision: revision, candidate: candidate, confirm: confirm)
            guard accepted else { return "这句已发生变化，请查看最新候选。" }
            let next = await coordinator.currentSnapshot
            if snapshot.sessionID == sessionID { receive(next) }
            return nil
        }
        var next = snapshot
        guard next.captions.reviewVocabularyCandidate(segmentID: segmentID, revision: revision, candidate: candidate, confirm: confirm) else {
            return "这句已发生变化，请查看最新候选。"
        }
        if let index = records.firstIndex(where: { $0.id == sessionID }) {
            var record = records[index]
            record.archive.items = next.captions.items.map {
                switch $0 { case .segment(let s): return .segment(s); case .gap(let g): return .gap(g) }
            }
            if record.saved {
                guard let store else { return "记录存储不可用，修订尚未保存。" }
                do { try store.save(record.archive) }
                catch { return "修订保存失败：\(error.localizedDescription)" }
            }
            records[index] = record
        }
        if !snapshot.state.isActive {
            // The terminal record is now authoritative. Late coordinator snapshots must
            // not reconstruct it from the pre-review reducer or lose its saved status.
            coordinator = nil
            snapshotTask?.cancel()
            snapshotTask = nil
        }
        apply(next, forcePresent: true)
        return nil
    }
    var overlayVisible = true {
        didSet {
            guard oldValue && !overlayVisible else { return }
            handleOverlayClosed()
        }
    }
    var overlayLocked = false
    var mainWindowVisible = true
    private(set) var isReconfiguringSession = false
    @ObservationIgnored private var overlayReconfigurationCancelled = false

    /// Sources the next session will use. "应用" and "系统声" are one capture slot: choosing one
    /// clears the other, so the title and the lanes can never disagree. The computer channel
    /// defaults to every application (the system mix); ticking applications narrows it.
    var useMicrophone = false
    var useApplication = false {
        didSet { if useApplication && useSystem { useSystem = false } }
    }
    var useSystem = true {
        didSet { if useSystem && useApplication { useApplication = false } }
    }
    /// Applications ticked for the computer channel, in the order they were ticked. Only used
    /// while `useApplication` is on; kept across "全部应用" so ticking again is one click.
    var selectedApplications: [RunningApplicationSummary] = []
    var selectedMicrophone: AudioInputDevice?
    /// Development override (`--autostart file:<path>`): the "系统声" lane reads this audio file
    /// through the production chain instead of a process tap, so a full GUI session runs without
    /// a consent dialog. Not persisted, never set from the UI.
    var captureFileOverride: URL?

    // Bookkeeping mutated at packet rate; nothing observes it, so keep it out of the registrar.
    @ObservationIgnored private var coordinator: SessionCoordinator?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var presentTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointTask: Task<Void, Never>?
    @ObservationIgnored private var liveFlushTask: Task<Void, Never>?
    @ObservationIgnored private var lastLivePublishNs: Int64 = 0
    private let liveIntervalNs: Int64 = 250_000_000
    @ObservationIgnored private var presenter = CaptionPresenter(dwellNs: 0)
    @ObservationIgnored private var presentedVersion: UInt64?
    @ObservationIgnored private var presentedSessionID: String?
    @ObservationIgnored private var lastSegmentLane: String?
    @ObservationIgnored private var smoothers: [String: LevelSmoother] = [:]
    @ObservationIgnored private var latestRMS: [String: Float] = [:]
    /// When the session on screen started (wall clock); nil before the first session. Observed:
    /// the live masthead writes the session's own start and day from it, so a session that runs
    /// past midnight keeps its day. Assigned once per start, where it always changes.
    private(set) var sessionStartedAt: Date?
    private let store: SessionStore?
    @ObservationIgnored private var checkpointFailureReported = false
    let isPreview: Bool

    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    init(settings: AppSettings, preview: SessionSnapshot? = nil, store: SessionStore? = nil, credentials: EngineCredentials? = nil) {
        self.settings = settings
        self.isPreview = preview != nil
        // Keys are read once here and again only when one is saved or deleted; previews read none.
        self.credentials = credentials ?? (preview == nil ? EngineCredentials.load() : .empty)
        self.credentialsVersion = settings.credentialsVersion
        self.blueprint = EngineBlueprint(settings: settings, credentials: self.credentials)
        if let preview {
            self.store = nil
            apply(preview, forcePresent: true)
            self.levels = Dictionary(uniqueKeysWithValues: preview.lanes.map { ($0.id, $0.capture.level > 0 ? min(1, $0.capture.level * 6) : 0.35) })
            // A plausible two seconds of speech for the top bar, deterministic per lane.
            self.waves = Dictionary(uniqueKeysWithValues: preview.lanes.map { ($0.id, Self.previewWave(seed: $0.id == "mic" ? 3 : 1, level: self.levels[$0.id] ?? 0)) })
            self.useMicrophone = preview.lanes.contains { $0.configuration.source.kind == .microphone }
            self.useApplication = preview.lanes.contains { $0.configuration.source.kind == .application }
            if let app = preview.lanes.first(where: { $0.configuration.source.kind == .application })?.configuration.source {
                self.selectedApplications = [RunningApplicationSummary(bundleIdentifier: app.bundleIdentifier ?? "preview", name: app.displayName, path: nil, pid: 0, isPlayingAudio: true)]
            }
        } else {
            self.store = store ?? SessionStore(directory: SessionStore.defaultDirectory())
            applyMode(settings.mode)
            refreshDevices()
            loadRecords()
            refreshEngineReadiness()
            observeEngineSettings()
        }
    }

    // MARK: - Derived

    var isActive: Bool { sessionState.isActive }
    var isRunning: Bool { sessionState == .running || sessionState == .degraded || sessionState == .reconnecting }
    var hasSource: Bool { useMicrophone || (useApplication && !selectedApplications.isEmpty) || useSystem }

    /// The computer channel's source as one capture descriptor, or nil when it is off (or on
    /// with no application ticked yet).
    var computerSource: AudioSourceDescriptor? {
        if useApplication {
            guard let first = selectedApplications.first else { return nil }
            return AudioSourceDescriptor(
                kind: .application,
                bundleIdentifier: first.bundleIdentifier,
                applicationPath: first.path,
                displayName: AudioSourceDescriptor.applicationsLabel(selectedApplications.map(\.name)),
                bundleIdentifiers: selectedApplications.map(\.bundleIdentifier)
            )
        }
        return useSystem ? .system : nil
    }

    /// "Safari", "Safari、Zoom", "Safari 等 3 个应用"; "选择应用" while nothing is ticked.
    var selectedApplicationsLabel: String { AudioSourceDescriptor.applicationsLabel(selectedApplications.map(\.name)) }

    func isSelected(_ app: RunningApplicationSummary) -> Bool {
        useApplication && selectedApplications.contains { $0.bundleIdentifier == app.bundleIdentifier }
    }
    var canStart: Bool { !dictation.isActive && !isCheckingSource && !isReconfiguringSession && !isActive && hasSource && startBlocker == nil }

    /// Directions the next session needs.
    var draftDirections: [LanguageDirection] {
        var out: [LanguageDirection] = []
        if useApplication || useSystem { out.append(LanguageDirection(source: settings.listenSourceLanguage, target: settings.listenTargetLanguage)) }
        if useMicrophone { out.append(LanguageDirection(source: settings.micSourceLanguage, target: settings.micTargetLanguage)) }
        return out
    }

    nonisolated static func pairKey(_ source: String, _ target: String) -> String { LanguageDirection(source: source, target: target).key }

    /// Why the next session cannot start with the current draft, in the user's words.
    var startBlocker: String? { startBlockerAdvice?.detail }

    /// The blocker with its fix. Microphone permission is checked before any lane is built;
    /// the configured stages need their models on disk or their keys in the Keychain.
    var startBlockerAdvice: RecoveryAdvice? {
        if useMicrophone, let mic = PermissionCenter.microphoneBlocker() { return mic }
        if blueprint.needsAppleOS, !LocalEngineAvailability.isSupportedOS {
            return RecoveryAdvice(title: "Apple 本机引擎需要 macOS 26", detail: "这台电脑的系统没有 SpeechAnalyzer / Translation。请在 设置 › 引擎 中改用其他识别与翻译引擎，或升级系统。", action: .openEngineSettings)
        }
        for d in draftDirections {
            if d.source == d.target {
                return RecoveryAdvice(title: "源语言与目标语言相同", detail: "「\(StatusCopy.direction(d.source, d.target))」没有可翻译的内容，请改一个方向。", action: nil)
            }
            if let status = readiness[d.key], let blocker = status.blocker {
                let wantsModels = blocker.contains("本地模型")
                return RecoveryAdvice(title: status.recognizer.isReady ? "翻译引擎未就绪" : "识别引擎未就绪", detail: blocker, action: wantsModels ? .openLocalModels : .openEngineSettings)
            }
        }
        return nil
    }

    /// What the window is showing. A session in progress (or a finished one still on screen)
    /// describes itself from its own lanes; only an empty window describes the draft.
    var sessionTitle: String {
        if !lanes.isEmpty { return Self.title(for: lanes) }
        return draftTitle
    }

    /// The next session's sources and directions, from the current settings.
    var draftTitle: String {
        let lanes = draftLanes
        return lanes.isEmpty ? "未选择来源" : lanes.map { $0.title() }.joined(separator: "  ·  ")
    }

    /// The lanes the next session would open, one per top-bar row: who it listens to and
    /// which way it translates. Same rule as `draftTitle`, which is built from these. The ids
    /// are the ones the session's lanes will carry ("remote" for the computer channel, "mic"),
    /// so the top bar's row keeps its identity across draft → session → draft and the resting
    /// ripple stays where the last session left it.
    var draftLanes: [DraftLane] {
        var out: [DraftLane] = []
        if useApplication, !selectedApplications.isEmpty {
            out.append(DraftLane(id: "remote", name: selectedApplicationsLabel, source: settings.listenSourceLanguage, target: settings.listenTargetLanguage))
        }
        if useSystem {
            out.append(DraftLane(id: "remote", name: "系统声", source: settings.listenSourceLanguage, target: settings.listenTargetLanguage))
        }
        if useMicrophone {
            out.append(DraftLane(id: "mic", name: "麦克风", source: settings.micSourceLanguage, target: settings.micTargetLanguage))
        }
        return out
    }

    static func title(for lanes: [LaneStatus]) -> String {
        lanes.map { laneTitle($0) }.joined(separator: "  ·  ")
    }

    var liveDotMode: LiveDot.Mode {
        switch sessionState {
        case .running, .degraded:
            let anyAudio = lanes.contains { $0.capture.state == .capturing }
            return anyAudio ? .live : .waiting
        case .reconnecting, .connecting, .preparing, .draining: return .waiting
        case .paused: return .paused
        default: return .hidden
        }
    }

    func level(for laneID: String) -> Float { levels[laneID] ?? 0 }

    /// The lane's sound line; a flat one before the first level tick.
    func wave(for laneID: String) -> WaveTrace { waves[laneID] ?? WaveTrace() }

    /// Speech-shaped envelope for previews: syllable bursts with pauses, no randomness.
    private static func previewWave(seed: Int, level: Float) -> WaveTrace {
        guard level > 0 else { return WaveTrace() }
        var samples: [Float] = []
        for i in 0..<WaveTrace.defaultLength {
            let t = Float(i) / 64
            let syllable = max(0, sin(t * Float.pi * (11 + Float(seed)) + Float(seed)))
            let breath = 0.55 + 0.45 * sin(t * Float.pi * 2.3 + Float(seed) * 0.7)
            samples.append(min(1, level * (0.35 + syllable * breath)))
        }
        return WaveTrace(samples: samples, phase: Float(seed) * 1.3)
    }

    /// The lane's line in the top bar: who it listens to, then its direction.
    static func laneTitle(_ lane: LaneStatus, withDirection: Bool = true) -> String {
        let source = lane.configuration.source
        let name = source.kind == .system ? "系统声" : (source.kind == .microphone ? "麦克风" : source.displayName)
        return withDirection ? "\(name) · \(StatusCopy.direction(lane.configuration.sourceLanguage, lane.configuration.targetLanguage))" : name
    }

    var isViewingRecord: Bool { viewingRecordID != nil }

    /// The record on screen, or the finished session that has not been cleared yet.
    var currentRecord: SessionRecord? {
        if let id = viewingRecordID { return records.first { $0.id == id } }
        if !sessionState.isActive, sessionState != .idle { return records.first { $0.id == sessionID } }
        return nil
    }

    var engineDescription: String {
        if blueprint.isLocal { return "当前使用 \(blueprint.summary)：识别与翻译都在这台电脑上完成，不联网；模型只在你点击下载时获取。" }
        return "当前使用 \(blueprint.summary)：\(blueprint.dataDestination)。费用按所选服务的计价发生，只在会话进行中产生。"
    }

    /// One phrase per direction for the empty state: ready, or what is missing.
    var readinessSummary: String {
        let parts = draftDirections.map { d -> String in
            guard let r = readiness[d.key] else { return readinessRefreshing ? "正在检查" : "未检查" }
            return "\(StatusCopy.direction(d.source, d.target)) \(r.summary)"
        }
        return parts.joined(separator: " · ")
    }

    var sessionsFolderURL: URL? { store?.directory }

    // MARK: - Setup

    func applyMode(_ mode: SessionMode) {
        settings.mode = mode
        switch mode {
        case .listen, .converse:
            useMicrophone = mode == .converse
            // The computer channel comes back the way it was last used: the ticked apps, or all.
            if settings.listenToApplications, !settings.lastAppBundleIDs.isEmpty {
                useApplication = true
            } else {
                useSystem = true
            }
        case .faceToFace:
            useMicrophone = true
            useApplication = false
            useSystem = false
        }
    }

    /// Refresh choices without reconciling or persisting a currently selected source.
    func refreshSourceInventory() {
        guard !isPreview else { return }
        applications = ApplicationAudioIdentityResolver.candidateApplications()
        microphones = AudioDeviceList.inputDevices()
    }

    func refreshDevices() {
        guard !isPreview else { return }
        refreshSourceInventory()
        // Restore the ticked set from the last run (only apps that still run), then refresh
        // every kept summary so "正在发声" stays current. Nothing is ticked on its own: a
        // playing app is listed first and labelled, never silently chosen.
        let wanted = selectedApplications.isEmpty ? settings.lastAppBundleIDs : selectedApplications.map(\.bundleIdentifier)
        let fresh: [RunningApplicationSummary] = wanted.compactMap { bid in
            if let running = applications.first(where: { $0.bundleIdentifier == bid }) { return running }
            // A ticked app that has quit stays ticked: the tap waits for it to come back.
            return selectedApplications.first { $0.bundleIdentifier == bid }
        }
        if fresh != selectedApplications { selectedApplications = fresh }
        if useApplication, selectedApplications.isEmpty, !settings.lastAppBundleIDs.isEmpty {
            // The remembered apps are not running: keep the channel on, fall back to all apps
            // so the draft still starts, and say so in the menu title through `useApplication`.
            useSystem = true
        }
        if selectedMicrophone == nil {
            if let last = settings.lastMicUID, let mic = microphones.first(where: { $0.uid == last }) {
                selectedMicrophone = mic
            } else {
                selectedMicrophone = microphones.first { $0.isDefault } ?? microphones.first
            }
        }
    }

    /// Ticks or unticks one application. Ticking narrows the computer channel to the ticked
    /// set; unticking the last one widens it back to all applications (the channel stays on).
    func toggle(application: RunningApplicationSummary) {
        guard !isActive else { return }
        if isSelected(application) {
            selectedApplications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
            if selectedApplications.isEmpty { useSystem = true }
        } else {
            if !useApplication { selectedApplications = [] }
            selectedApplications.append(application)
            useApplication = true
        }
        rememberComputerSource()
    }

    /// "全部应用（系统声）": every application, the ticked set kept for next time.
    func selectAllApplications() {
        guard !isActive else { return }
        useSystem = true
        rememberComputerSource()
    }

    /// Replaces the ticked set (command line, tests); an empty set means all applications.
    func select(applications apps: [RunningApplicationSummary]) {
        selectedApplications = apps
        if apps.isEmpty { useSystem = true } else { useApplication = true }
        rememberComputerSource()
    }

    private func rememberComputerSource() {
        settings.listenToApplications = useApplication
        if !selectedApplications.isEmpty { settings.lastAppBundleIDs = selectedApplications.map(\.bundleIdentifier) }
    }

    func select(microphone: AudioInputDevice?) {
        selectedMicrophone = microphone
        settings.lastMicUID = microphone?.uid
    }

    /// Rebuilds the blueprint from settings and the Keychain, then re-asks both stages about
    /// every direction in the draft. Read-only: no model downloads, no network.
    func refreshEngineReadiness() {
        guard !isPreview else { return }
        if settings.credentialsVersion != credentialsVersion {
            credentialsVersion = settings.credentialsVersion
            credentials = EngineCredentials.load()
        }
        let fresh = EngineBlueprint(settings: settings, credentials: credentials)
        if fresh != blueprint { blueprint = fresh }
        let directions = draftDirections
        guard !directions.isEmpty else { return }
        readinessRefreshing = true
        let bp = blueprint
        Task { [weak self] in
            var out: [String: EngineReadiness] = [:]
            for d in directions {
                out[d.key] = await bp.readiness(source: d.source == LanguageCatalog.auto ? nil : d.source, target: d.target)
            }
            guard let self else { return }
            for (k, v) in out where self.readiness[k] != v { self.readiness[k] = v }
            self.readinessRefreshing = false
        }
    }

    /// Languages, engine and sources are plain settings; watch them so the readiness cache
    /// follows the draft without every view having to remember to refresh it.
    private func observeEngineSettings() {
        withObservationTracking {
            _ = settings.recognizer
            _ = settings.whisperModel
            _ = settings.translator
            _ = settings.chatVendor
            _ = settings.realtimeBaseURL
            _ = settings.realtimeModel
            _ = settings.realtimeLegacyProtocol
            _ = settings.deepgramModel
            _ = settings.anthropicModel
            _ = settings.geminiModel
            _ = settings.cloudPartialTranslation
            _ = settings.hotWords
            _ = settings.glossaryLines
            _ = settings.credentialsVersion
            _ = settings.chatBaseURL(for: settings.chatVendor)
            _ = settings.chatModel(for: settings.chatVendor)
            _ = settings.listenSourceLanguage
            _ = settings.listenTargetLanguage
            _ = settings.micSourceLanguage
            _ = settings.micTargetLanguage
            _ = useMicrophone
            _ = useApplication
            _ = useSystem
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshEngineReadiness()
                self.observeEngineSettings()
            }
        }
    }

    // MARK: - Session commands

    func start() {
        startSession(navigateHome: true)
    }

    private func startSession(navigateHome: Bool, showOverlay: Bool = true) {
        guard canStart, !isPreview else { return }
        if navigateHome { mainPage = .home }
        let blueprint = self.blueprint
        let providerID = EngineBlueprint.providerID
        var lanes: [LaneConfiguration] = []
        // "自动" in settings is nil on the wire: the recognizer detects the language.
        func sourceLanguage(_ code: String) -> String? { code == LanguageCatalog.auto ? nil : code }
        if let computer = computerSource {
            lanes.append(LaneConfiguration(id: "remote", source: computer, sourceLanguage: sourceLanguage(settings.listenSourceLanguage), targetLanguage: settings.listenTargetLanguage, providerID: providerID))
        }
        if useMicrophone {
            let mic = selectedMicrophone
            lanes.append(LaneConfiguration(id: "mic", source: AudioSourceDescriptor(kind: .microphone, deviceUID: mic?.uid, displayName: mic?.name ?? "默认麦克风"), sourceLanguage: sourceLanguage(settings.micSourceLanguage), targetLanguage: settings.micTargetLanguage, providerID: providerID))
        }
        let coordinator = SessionCoordinator()
        self.coordinator = coordinator
        sessionStartedAt = Date()
        viewingRecordID = nil
        sourceCheckReport = nil
        checkpointFailureReported = false
        // Starting a session means the user wants captions: bring the overlay back if it was hidden.
        if showOverlay { overlayVisible = true }
        overlayLocked = false
        smoothers = [:]
        latestRMS = [:]
        levels = [:]
        // The envelope starts flat; each lane's ripple phase is kept, so the resting line
        // starts moving from where it rested instead of jumping to a new curve.
        waves = waves.mapValues { WaveTrace(samples: Array(repeating: 0, count: WaveTrace.defaultLength), phase: $0.phase) }
        spokenSegments = []
        announcedSegments = []
        readAloud.reset()
        let anchor = MonotonicClock.nowNs()
        let captureFile = captureFileOverride
        let factories = LaneFactories(
            makeCapture: { cfg in
                switch cfg.source.kind {
                case .microphone: return MicrophoneCapture(laneID: cfg.id, sessionAnchorNs: anchor)
                case .system where captureFile != nil: return FileCapture(laneID: cfg.id, sessionAnchorNs: anchor, url: captureFile!)
                case .application, .system: return ProcessTapCapture(laneID: cfg.id, sessionAnchorNs: anchor)
                }
            },
            makeProvider: { _ in try blueprint.makeProvider() }
        )
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            for await snap in coordinator.snapshots {
                guard let self, !Task.isCancelled, self.coordinator?.sessionID == coordinator.sessionID else { return }
                self.receive(snap)
            }
        }
        startLevelLoop()
        startCheckpointLoop()
        Task {
            await coordinator.start(lanes: lanes, factories: factories)
        }
    }

    func pause() {
        speech.stop()
        guard let coordinator else { return }
        Task { await coordinator.pause() }
    }
    func resume() {
        guard let coordinator else { return }
        Task { await coordinator.resume() }
    }

    func stop() {
        overlayReconfigurationCancelled = true
        speech.stop()
        guard let coordinator else { return }
        Task { await coordinator.stop() }
    }

    /// Check the draft before touching the live session. A language change needs new engine
    /// instances; finish and archive the old coordinator before starting the new direction.
    func applyOverlayLanguages(_ selection: OverlayLanguages) async -> String? {
        await applyOverlayConfiguration(languages: selection, recognizer: settings.recognizer,
                                        whisperModel: settings.whisperModel, translator: settings.translator)
    }

    func applySessionSources(_ selection: SessionSourceSelection) async -> String? {
        if let error = selection.validationError { return error }
        if selection.microphoneEnabled, let blocker = PermissionCenter.microphoneBlocker() { return blocker.detail }
        return await applyOverlayConfiguration(languages: selection.languages, recognizer: settings.recognizer,
                                               whisperModel: settings.whisperModel, translator: settings.translator,
                                               sources: selection)
    }

    func applyOverlayTranslator(_ translator: TranslatorChoice) async -> String? {
        await applyOverlayEngines(recognizer: settings.recognizer, whisperModel: settings.whisperModel, translator: translator)
    }

    func applyOverlayEngines(recognizer: RecognizerChoice, whisperModel: String, translator: TranslatorChoice) async -> String? {
        await applyOverlayConfiguration(languages: OverlayLanguages(settings: settings), recognizer: recognizer,
                                        whisperModel: whisperModel, translator: translator)
    }

    private func applyOverlayConfiguration(languages selection: OverlayLanguages, recognizer: RecognizerChoice,
                                           whisperModel: String, translator: TranslatorChoice,
                                           sources: SessionSourceSelection? = nil) async -> String? {
        guard !isReconfiguringSession else { return "正在切换会话配置，请稍候。" }
        let directions = selection.directions(computer: sources.map { $0.computer != .off } ?? (useApplication || useSystem),
                                              microphone: sources?.microphoneEnabled ?? useMicrophone)
        guard !directions.isEmpty else { return "请先选择声音来源。" }
        guard directions.allSatisfy({ $0.source != $0.target }) else { return "识别语言和输出语言需要不同。" }
        guard directions.allSatisfy({ ($0.source == LanguageCatalog.auto || LanguageCatalog.codes.contains($0.source)) && LanguageCatalog.codes.contains($0.target) }) else {
            return "请选择列表中的语言。"
        }
        guard !isPreview else { return "预览中无法重新启动语音引擎。" }
        guard sessionState != .draining && sessionState != .stopping && sessionState != .preparing && sessionState != .connecting else {
            return "请等当前会话就绪后再切换。"
        }
        isReconfiguringSession = true
        overlayReconfigurationCancelled = false
        defer { isReconfiguringSession = false }
        let originalID = sessionID
        let wasActive = isActive
        let originalSources = SessionSourceSelection(model: self)
        let wasLocked = overlayLocked
        let originalBlueprint = blueprint
        var proposedBlueprint = blueprint
        proposedBlueprint.recognizer = recognizer
        proposedBlueprint.whisper.variant = whisperModel
        proposedBlueprint.translator = translator
        var checked: [String: EngineReadiness] = [:]
        for direction in directions {
            let result = await proposedBlueprint.readiness(source: direction.source == LanguageCatalog.auto ? nil : direction.source, target: direction.target)
            guard result.isReady else { return result.blocker ?? "这个语言方向的引擎尚未就绪。" }
            checked[direction.key] = result
        }
        guard !overlayReconfigurationCancelled, sessionID == originalID, isActive == wasActive,
              blueprint == originalBlueprint, SessionSourceSelection(model: self) == originalSources else {
            return "会话状态已改变，请重新应用设置。"
        }
        if wasActive, let coordinator {
            speech.stop()
            await coordinator.stop()
            let terminal = await coordinator.currentSnapshot
            guard terminal.state == .completed || terminal.state == .failed else { return "会话尚未结束，请稍后再试。" }
            // The stream may not have delivered its final item yet. Read and archive that
            // item explicitly before start() cancels the old stream and replaces its model.
            snapshotTask?.cancel()
            receive(terminal)
        }
        guard !overlayReconfigurationCancelled else { return "已停止会话，本次切换已取消。" }
        sources?.apply(to: self)
        selection.apply(to: settings)
        settings.recognizer = recognizer
        settings.whisperModel = whisperModel
        settings.translator = translator
        blueprint = proposedBlueprint
        for (key, value) in checked { readiness[key] = value }
        if wasActive {
            isReconfiguringSession = false
            guard canStart else { return startBlocker ?? "设置已保存，请从主窗口重新开始。" }
            startSession(navigateHome: false, showOverlay: false)
            overlayLocked = wasLocked
        }
        return nil
    }

    func togglePause() {
        guard canPauseOrResume else { return }
        if snapshot.state == .paused { resume() } else { pause() }
    }

    func clearCompleted() {
        guard !isActive else { return }
        mainPage = .home
        viewingRecordID = nil
        coordinator = nil
        apply(.empty(), forcePresent: true)
    }

    /// Reopens a finished session in the reading column. Nothing is captured or uploaded.
    func showRecord(_ record: SessionRecord) {
        guard !isActive else { return }
        mainPage = .transcript
        coordinator = nil
        viewingRecordID = record.id
        apply(record.archive.displaySnapshot(), forcePresent: true)
    }

    func receive(_ snap: SessionSnapshot) {
        if snap.state != snapshot.state {
            modelLog.notice("session \(snap.sessionID, privacy: .public) → \(snap.state.rawValue, privacy: .public) segments=\(snap.captions.segments.count, privacy: .public) lanes=\(snap.lanes.map { "\($0.id):\($0.capture.state.rawValue)/\($0.providerLink.rawValue)" }.joined(separator: ","), privacy: .public)\(snap.failure.map { " failure=\($0)" } ?? "", privacy: .public)")
        }
        for lane in snap.lanes {
            latestRMS[lane.id] = lane.capture.level
        }
        apply(snap)
        if !snap.state.isActive {
            levelTask?.cancel()
            levelTask = nil
            checkpointTask?.cancel()
            checkpointTask = nil
            recordIfTerminal(snap)
        }
    }

    /// Every way a session can end (stop, engine close, error) passes through a terminal
    /// snapshot, so the record is created here and only here, once per session id. Auto-save
    /// writes it to disk at the same moment; otherwise it stays in memory until the user saves.
    private func recordIfTerminal(_ snap: SessionSnapshot) {
        guard snap.state == .completed || snap.state == .failed, !snap.lanes.isEmpty else { return }
        let segments = snap.captions.segments
        if snap.state == .failed, segments.isEmpty {
            store?.clearCheckpoint(id: snap.sessionID)
            return  // a start that never produced anything
        }
        let archive = SessionArchive(snapshot: snap, title: Self.title(for: snap.lanes), startedAt: sessionStartedAt ?? Date(), outcome: snap.state == .failed ? .failed : .completed, appVersion: Self.appVersion)
        var record = SessionRecord(archive: archive, saved: false)
        let previouslySaved = records.first { $0.id == snap.sessionID }?.saved == true
        if settings.autoSaveSessions || previouslySaved, let store {
            do {
                try store.save(archive)
                record.saved = true
            } catch {
                storeMessage = "自动保存失败：\(error)"
                modelLog.error("auto-save failed: \(String(describing: error), privacy: .public)")
            }
        }
        store?.clearCheckpoint(id: snap.sessionID)
        if let i = records.firstIndex(where: { $0.id == snap.sessionID }) {
            records[i] = record
        } else {
            records.insert(record, at: 0)
        }
    }

    // MARK: - Records on disk

    private func loadRecords() {
        guard let store else { return }
        let recovered = store.recoverCheckpoints()
        let all = store.loadAll()
        records = all.archives.map { SessionRecord(archive: $0, saved: true) }
        if !recovered.isEmpty {
            storeMessage = "上次有 \(recovered.count) 次会话未正常结束，已从自动保存恢复"
        } else if !all.problems.isEmpty {
            storeMessage = "有 \(all.problems.count) 个记录文件无法读取"
            for p in all.problems { modelLog.error("unreadable record: \(p, privacy: .public)") }
        }
    }

    func save(_ record: SessionRecord) {
        guard let store, let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        do {
            let url = try store.save(record.archive)
            records[i].saved = true
            storeMessage = "已保存到 \(url.lastPathComponent)"
        } catch {
            storeMessage = "保存失败：\(error)"
        }
    }

    func delete(_ record: SessionRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        if record.saved, let store {
            do {
                try store.delete(id: record.id)
            } catch {
                storeMessage = "删除失败：\(error)"
                return
            }
        }
        records.remove(at: i)
        if viewingRecordID == record.id { clearCompleted() }
        if snapshot.sessionID == record.id, !isActive { clearCompleted() }
        storeMessage = "已删除「\(record.title)」"
    }

    func deleteAllSavedRecords() {
        guard let store else { return }
        var failed = 0
        for r in records where r.saved {
            do { try store.delete(id: r.id) } catch { failed += 1 }
        }
        records.removeAll { $0.saved }
        if viewingRecordID != nil, records.first(where: { $0.id == viewingRecordID }) == nil { clearCompleted() }
        storeMessage = failed == 0 ? "已删除全部已保存的记录" : "有 \(failed) 条记录删除失败"
    }

    /// Renders one record for export; the caller picks the destination (save panel).
    func exportText(_ record: SessionRecord, format: ExportFormat) throws -> (text: String, fileName: String) {
        (try TranscriptExporter.render(record.archive, format: format), TranscriptExporter.suggestedFileName(record.archive, format: format))
    }

    func noteExport(result: String) {
        storeMessage = result
    }

    func revealInFinder(_ record: SessionRecord) {
        guard record.saved, let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url(for: record.id)])
    }

    /// Crash protection: while auto-save is on, the running session is written every few
    /// seconds as an "in progress" file; the next launch turns a leftover into a record.
    private func startCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = nil
        guard store != nil else { return }
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.writeCheckpoint()
            }
        }
    }

    /// Synchronous so it can run from `applicationWillTerminate`.
    func writeCheckpoint() {
        guard settings.autoSaveSessions, let store, isActive, !snapshot.captions.segments.isEmpty else { return }
        let archive = SessionArchive(snapshot: snapshot, title: Self.title(for: snapshot.lanes), startedAt: sessionStartedAt ?? Date(), outcome: .interrupted, appVersion: Self.appVersion)
        do {
            try store.writeCheckpoint(archive)
        } catch {
            if !checkpointFailureReported {
                checkpointFailureReported = true
                storeMessage = "自动保存写入失败：\(error)"
            }
        }
    }

    // MARK: - Recovery and self-check

    func perform(_ action: RecoveryAction) {
        switch action {
        case .openMicrophoneSettings:
            PermissionCenter.open(PermissionCenter.microphoneSettingsURL)
        case .openAudioCaptureSettings:
            PermissionCenter.open(PermissionCenter.audioCaptureSettingsURL)
        case .openLocalModels:
            // The page always exists now: Whisper works from macOS 15, and the Apple group
            // explains itself on an older system.
            settings.requestedSettingsTab = .localModels
            openSettingsRequest += 1
        case .openEngineSettings:
            settings.requestedSettingsTab = .engine
            openSettingsRequest += 1
        case .reselectMicrophone:
            refreshDevices()
            if let current = selectedMicrophone, microphones.contains(current) { return }
            select(microphone: microphones.first { $0.isDefault } ?? microphones.first)
        case .openSessionsFolder:
            guard let store else { return }
            try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(store.directory)
        }
    }

    func requestSettings(_ tab: SettingsTab) {
        if tab == .vocabulary { requestVocabularyWindow(); return }
        settings.requestedSettingsTab = tab
        openSettingsRequest += 1
    }

    /// Runs the real capture path for each chosen source for a few seconds and reports.
    func runSourceCheck() {
        guard !dictation.isActive, !isActive, !isCheckingSource, !isPreview else { return }
        var sources: [AudioSourceDescriptor] = []
        if let computer = computerSource { sources.append(computer) }
        if useMicrophone {
            let mic = selectedMicrophone
            sources.append(AudioSourceDescriptor(kind: .microphone, deviceUID: mic?.uid, displayName: mic?.name ?? "默认麦克风"))
        }
        guard !sources.isEmpty else { return }
        isCheckingSource = true
        sourceCheckReport = nil
        openSourceCheckRequest += 1
        sourceCheckTask = Task { [weak self] in
            var reports: [SourceCheck.Report] = []
            for s in sources {
                if Task.isCancelled { break }
                reports.append(await SourceCheck.run(s))
            }
            guard let self else { return }
            self.isCheckingSource = false
            self.sourceCheckTask = nil
            guard !Task.isCancelled else { return }
            self.sourceCheckReport = .combining(reports)
        }
    }

    func clearSourceCheck() { sourceCheckReport = nil }
    func cancelSourceCheck() { sourceCheckTask?.cancel() }

    // MARK: - Display state

    /// The single entry point for a new snapshot (live publish, record view, preview, clear).
    /// Splits it into the fine-grained properties the views read, assigning each only when it
    /// actually changed, and re-runs the presenter only when the captions changed.
    private func apply(_ snap: SessionSnapshot, forcePresent: Bool = false) {
        snapshot = snap
        if snap.state != sessionState { sessionState = snap.state }
        if snap.sessionID != sessionID { sessionID = snap.sessionID }
        let display = snap.lanes.map(Self.displayLane)
        var laneSetChanged = false
        if display != lanes {
            laneSetChanged = display.map(\.id) != lanes.map(\.id)
            lanes = display
        }
        let seconds = (snap.elapsedNs / 1_000_000_000) * 1_000_000_000
        if seconds != elapsedNs { elapsedNs = seconds }
        if forcePresent || snap.captions.version != presentedVersion || snap.captions.sessionID != presentedSessionID {
            present()
        } else if laneSetChanged {
            rebuildRows()
        }
        refreshDerived(snap)
        publishLive(snap)
    }

    /// A lane as the views need it: everything that changes per audio packet is removed, so the
    /// array compares equal between packets and `lanes` only changes on a real state change.
    private static func displayLane(_ lane: LaneStatus) -> LaneStatus {
        var l = lane
        l.capture.level = 0
        l.capture.peak = 0
        l.capture.callbackCount = min(1, lane.capture.callbackCount)
        l.capture.lastAudioNs = nil
        l.capture.queuedNs = 0
        l.sentWatermarkNs = 0
        l.capturedWatermarkNs = 0
        return l
    }

    /// Status line, lag, recovery advice and tail placeholders from the raw snapshot.
    private func refreshDerived(_ snap: SessionSnapshot) {
        let status = StatusCopy.session(snap)
        if status != rawStatusText { rawStatusText = status }
        var lag: String? = nil
        if snap.state == .running || snap.state == .degraded || snap.state == .reconnecting {
            let backlog = snap.lanes.map(\.backlogNs).max() ?? 0
            if backlog > 300_000_000 { lag = "滞后 \(StatusCopy.seconds(backlog))" }
        }
        if lag != lagText { lagText = lag }
        var advice = PermissionCenter.advice(forSession: snap)
        if advice == nil, snap.state.isActive {
            for lane in snap.lanes {
                if let a = PermissionCenter.advice(for: lane, elapsedNs: snap.elapsedNs) { advice = a; break }
            }
        }
        if advice != recoveryAdvice { recoveryAdvice = advice }
        rebuildListening()
    }

    /// Inspector feed: the raw snapshot at most every `liveIntervalNs`, with a trailing flush so
    /// the last publish of a burst always lands; state and lane-set changes go through at once.
    private func publishLive(_ snap: SessionSnapshot) {
        let now = MonotonicClock.nowNs()
        let urgent = !snap.state.isActive || snap.state != liveSnapshot.state || snap.sessionID != liveSnapshot.sessionID || snap.lanes.count != liveSnapshot.lanes.count
        if urgent || now - lastLivePublishNs >= liveIntervalNs {
            liveFlushTask?.cancel()
            liveFlushTask = nil
            lastLivePublishNs = now
            liveSnapshot = snap
        } else if liveFlushTask == nil {
            let delay = UInt64(max(liveIntervalNs - (now - lastLivePublishNs), 1_000_000))
            liveFlushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled else { return }
                self.liveFlushTask = nil
                self.lastLivePublishNs = MonotonicClock.nowNs()
                self.liveSnapshot = self.snapshot
            }
        }
    }

    static func tag(for lane: LaneStatus) -> String {
        switch lane.configuration.source.kind {
        case .microphone: return "麦克风"
        case .application: return "应用"
        case .system: return "系统声"
        }
    }

    /// Rows, per-lane tails and the gap count from the presented captions. O(n) once per
    /// caption change instead of once per view body.
    private func rebuildRows() {
        let tags = Dictionary(lanes.map { ($0.id, Self.tag(for: $0)) }, uniquingKeysWith: { a, _ in a })
        var rows: [TranscriptRow] = []
        rows.reserveCapacity(captions.items.count)
        var tails: [String: LaneTail] = [:]
        let sourceByID = Dictionary(captions.segments.map { ($0.id, $0.sourceText) }, uniquingKeysWith: { _, newer in newer })
        var previousLane: String?
        var gaps = 0
        lastSegmentLane = nil
        for item in captions.items {
            switch item {
            case .segment(let seg):
                rows.append(TranscriptRow(item: item, tag: seg.laneID != previousLane ? (tags[seg.laneID] ?? seg.laneID) : nil))
                previousLane = seg.laneID
                lastSegmentLane = seg.laneID
                if seg.mergedIntoTranslation != nil { continue }
                var t = tails[seg.laneID] ?? LaneTail()
                t.earlier = t.previous
                t.previous = t.current
                t.current = seg
                if let covered = seg.translation?.coveredSegmentIDs, covered.count > 1 {
                    t.current?.sourceText = covered.compactMap { sourceByID[$0] }.joined(separator: " ")
                }
                tails[seg.laneID] = t
            case .gap(let gap):
                rows.append(TranscriptRow(item: item, tag: nil))
                previousLane = nil
                gaps += 1
                var t = tails[gap.laneID] ?? LaneTail()
                t.lastGap = gap
                tails[gap.laneID] = t
            }
        }
        if rows != transcriptRows { transcriptRows = rows }
        if tails != laneTails { laneTails = tails }
        if gaps != gapCount { gapCount = gaps }
    }

    /// Tail placeholders: one per running lane that has no open sentence. A lane that has
    /// stopped or failed gets no "正在听" row; the failure card and the sidebar already say so.
    private func rebuildListening() {
        var rows: [ListeningRowModel] = []
        if isRunning {
            for lane in lanes {
                if lane.capture.state == .failed || lane.capture.state == .stopped { continue }
                if let s = laneTails[lane.id]?.current, s.presentationState != .final, s.presentationState != .frozen { continue }
                let labelled = lane.id == lastSegmentLane && lanes.count == 1
                rows.append(ListeningRowModel(laneID: lane.id, tag: labelled ? nil : Self.tag(for: lane), text: Self.listeningText(lane), live: lane.capture.state == .capturing))
            }
        }
        if rows != listeningRows { listeningRows = rows }
    }

    /// 朗读译文: each finalized translation once, for the channels the user switched on. The
    /// voice is the target language's; the gate skips what was read already.
    private func announceFinals() {
        postAccessibilityFinals()
        guard isRunning, settings.readAloudComputer || settings.readAloudMicrophone else { return }
        for case .segment(let seg) in captions.items {
            guard seg.presentationState == .final || seg.presentationState == .frozen,
                  let t = seg.translation, t.isFinal, !t.text.isEmpty,
                  !spokenSegments.contains(seg.id),
                  let lane = lanes.first(where: { $0.id == seg.laneID }) else { continue }
            spokenSegments.insert(seg.id)
            let wanted = lane.configuration.source.kind == .microphone ? settings.readAloudMicrophone : settings.readAloudComputer
            guard wanted, let text = readAloud.speakable(t.text) else { continue }
            speech.speak(text, language: lane.configuration.targetLanguage)
        }
    }

    /// VoiceOver hears each translation once it is final (§11 读屏只朗读定稿句), and only the
    /// newest one per pass, so a burst never queues a backlog. Partials are never announced.
    private func postAccessibilityFinals() {
        guard isRunning, NSWorkspace.shared.isVoiceOverEnabled else { return }
        var latest: String?
        for case .segment(let seg) in captions.items {
            guard seg.presentationState == .final || seg.presentationState == .frozen,
                  let t = seg.translation, t.isFinal, !t.text.isEmpty,
                  !announcedSegments.contains(seg.id) else { continue }
            announcedSegments.insert(seg.id)
            latest = t.text
        }
        guard let latest else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: latest, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private static func listeningText(_ lane: LaneStatus) -> String {
        switch lane.capture.state {
        case .waitingForAudio: return lane.configuration.source.kind == .microphone ? "等待你说话" : "等待 \(lane.configuration.source.displayName) 发声"
        case .capturing: return "正在听"
        case .sourceIdle: return "暂时没有声音"
        case .sourceUnavailable: return "\(lane.configuration.source.displayName) 已退出"
        case .permissionRequired: return "需要权限"
        case .recovering: return "正在恢复"
        case .failed, .stopped: return "通道已停止"
        case .idle: return "准备中"
        }
    }

    // MARK: - Presentation (stability preset)

    private func present() {
        presenter.dwellNs = Int64(settings.stability.previewDwellMs) * 1_000_000
        presentedVersion = snapshot.captions.version
        presentedSessionID = snapshot.captions.sessionID
        let result = presenter.present(snapshot.captions, nowNs: MonotonicClock.nowNs())
        if result.snapshot != captions {
            captions = result.snapshot
            let candidates = captions.segments.reduce(0) { $0 + ($1.vocabularyCandidates?.count ?? 0) }
            if candidates != vocabularyCandidateCount { vocabularyCandidateCount = candidates }
            rebuildRows()
            rebuildListening()
            announceFinals()
        }
        presentTask?.cancel()
        presentTask = nil
        if let next = result.nextCheckNs {
            let delay = max(1_000_000, next - MonotonicClock.nowNs())
            presentTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay))
                guard !Task.isCancelled, let self else { return }
                self.present()
            }
        }
    }

    private func startLevelLoop() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { return }
                let now = MonotonicClock.nowNs()
                var next: [String: Float] = [:]
                var nextWaves = self.waves
                for (lane, rms) in self.latestRMS {
                    var s = self.smoothers[lane] ?? LevelSmoother()
                    // 1/255 steps: the release tail settles on a step and stops publishing.
                    let level = (s.feed(rms: rms, nowNs: now) * 255).rounded() / 255
                    next[lane] = level
                    self.smoothers[lane] = s
                    var w = nextWaves[lane] ?? WaveTrace()
                    w.push(level: level)
                    nextWaves[lane] = w
                }
                if next != self.levels { self.levels = next }
                // A flat trace pushed a zero is the same trace: silence publishes nothing.
                if nextWaves != self.waves { self.waves = nextWaves }
            }
        }
    }

    // MARK: - Overlay

    /// Every user-facing hide path goes through the visibility edge, including SwiftUI bindings.
    private func handleOverlayClosed() {
        guard settings.controlSessionOnOverlayClose else { return }
        // Closing during an engine/language switch must not allow its pending restart to
        // bring the overlay (and listening) back after the user asked to stop.
        overlayReconfigurationCancelled = true
        guard isActive else { return }
        switch settings.overlayCloseAction {
        case .endSession: stop()
        case .pause: pause()
        }
    }

    var overlayCloseHelp: String {
        guard settings.controlSessionOnOverlayClose else { return "隐藏字幕，会话继续；⌘⇧H 或菜单栏可再显示" }
        switch settings.overlayCloseAction {
        case .endSession: return "隐藏字幕并结束会话，保留已有记录"
        case .pause: return "隐藏字幕并暂停会话；重新显示字幕不会自动继续监听"
        }
    }

    func hideOverlay() { overlayVisible = false }
    func toggleOverlay() { overlayVisible.toggle() }
    func toggleLock() { overlayLocked.toggle() }
}

/// A lane the next session would open, as the top bar lists it before anything runs.
struct DraftLane: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var source: String
    var target: String

    /// "系统声 · 英语 → 中文", or just the name when the column is narrow.
    func title(withDirection: Bool = true) -> String {
        withDirection ? "\(name) · \(StatusCopy.direction(source, target))" : name
    }
}

/// One source → target pair as the UI lists it; `key` is stable and unique per pair.
struct LanguageDirection: Hashable, Identifiable, Sendable {
    var source: String
    var target: String
    var key: String { "\(source)>\(target)" }
    var id: String { key }
}
