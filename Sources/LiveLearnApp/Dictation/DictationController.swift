import AppKit
import Observation
import AudioDomain
import EngineKit
import MacAudio
import SessionDomain
import ProviderAdapters

enum DictationPhase: String {
    case idle, selectingInput, starting, listening, finishing, correcting, completed, failed
    var title: String {
        switch self {
        case .idle: "语音输入"
        case .selectingInput: "点选输入框，开始说话"
        case .starting: "正在准备麦克风…"
        case .listening: "正在听写"
        case .finishing: "正在确认最后一句…"
        case .correcting: "正在完成纠错…"
        case .completed: "听写完成"
        case .failed: "语音输入已停止"
        }
    }
}

@MainActor @Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    private(set) var text = ""
    private(set) var notice: String?
    private(set) var targetName = "预览"
    private(set) var targetFrame: CGRect?
    private(set) var meter = DictationMeter()
    private(set) var rawText = ""
    private(set) var cleaningUp = false
    private(set) var delivered = false
    private(set) var deliveryConfirmed = false
    let settings: DictationSettings
    @ObservationIgnored var configuration: (() throws -> DictationConfiguration)?
    @ObservationIgnored var startBlocker: (() -> String?)?
    @ObservationIgnored var targetFactory: () throws -> any DictationTextTarget = { try DictationInputTarget.capture() }
    @ObservationIgnored var captureFactory: () -> any AudioCapture = {
        MicrophoneCapture(laneID: "dictation", sessionAnchorNs: MonotonicClock.nowNs())
    }
    @ObservationIgnored private var target: (any DictationTextTarget)?
    @ObservationIgnored private var hasWrittenToTarget = false
    @ObservationIgnored private var capture: (any AudioCapture)?
    @ObservationIgnored private var recognizer: (any SpeechRecognizer)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var audioTask: Task<Void, Never>?
    @ObservationIgnored private var forwardingTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryTask: Task<Void, Error>?
    @ObservationIgnored private var captureStarted = false
    @ObservationIgnored private var finishWhenReady = false
    @ObservationIgnored private var heldSource: String?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lifetime: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var document = DictationDocument()
    @ObservationIgnored private var sessionConfig: DictationConfiguration?
    @ObservationIgnored private var panel: DictationPanelController?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var suspendedReasons: Set<String> = []

    init(settings: DictationSettings) { self.settings = settings }
    #if DEBUG
    var verificationWindow: NSWindow? { panel?.panel }
    #endif
    var isActive: Bool { cleaningUp || [.selectingInput, .starting, .listening, .finishing, .correcting].contains(phase) }

    func install() {
        guard panel == nil else { return }
        panel = DictationPanelController(controller: self)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, reason: "sleep", available: false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, reason: "session", available: false)
        observe(workspace, NSWorkspace.screensDidSleepNotification, reason: "display", available: false)
        observe(workspace, NSWorkspace.didWakeNotification, reason: "sleep", available: true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, reason: "session", available: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, reason: "display", available: true)
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked"), reason: "lock", available: false)
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsUnlocked"), reason: "lock", available: true)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: String, available: Bool) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if available { self.suspendedReasons.remove(reason) }
                else { self.suspendedReasons.insert(reason) }
                if !available { self.cancel(hide: true, immediately: true) }
            }
        }
        observers.append((center, observer))
    }

    func beginHolding(source: String) {
        guard !isActive, heldSource == nil else { return }
        start()
        if phase == .starting || phase == .listening { heldSource = source }
    }

    func endHolding(source: String) {
        guard heldSource == source else { return }
        heldSource = nil
        if phase == .listening { finish() }
        else if phase == .starting {
            if captureStarted, let capture {
                finishWhenReady = true
                Task { await capture.stop() }
            } else { cancel() }
        }
    }

    func toggle() {
        if phase == .listening { finish() }
        else if phase == .starting || phase == .selectingInput { cancel() }
        else if !isActive { start() }
    }

    func startFromInterface() {
        guard !isActive else { return }
        if let blocker = startBlocker?() { notice = blocker; phase = .failed; return }
        guard DictationInputTarget.accessibilityGranted else {
            text = ""; delivered = false; deliveryConfirmed = false
            notice = DictationInputError.permission.description; phase = .failed; panel?.show()
            DictationInputTarget.requestAccessibility()
            return
        }
        NSApp.hide(nil)
        selectInputAndStart()
    }

    func selectInputAndStart() {
        guard !isActive, suspendedReasons.isEmpty else { return }
        if let blocker = startBlocker?() { notice = blocker; phase = .failed; return }
        generation = UUID(); let id = generation
        text = ""; rawText = ""; notice = nil; target = nil; targetFrame = nil; delivered = false; deliveryConfirmed = false
        phase = .selectingInput; panel?.show()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                for _ in 0..<300 {
                    try await Task.sleep(for: .milliseconds(100))
                    try self.check(id)
                    do {
                        let input = try self.targetFactory()
                        self.phase = .idle
                        self.start(previewOnly: false, capturedTarget: input)
                        return
                    } catch DictationInputError.unsupported { continue }
                }
                self.fail("未选中输入框，请点击要输入的位置后重试。")
            } catch {
                if self.generation == id { self.fail(String(describing: error)) }
            }
        }
    }

    func start(previewOnly: Bool = false) {
        start(previewOnly: previewOnly, capturedTarget: nil)
    }

    private func start(previewOnly: Bool, capturedTarget: (any DictationTextTarget)?) {
        guard !isActive, suspendedReasons.isEmpty else { return }
        if let blocker = startBlocker?() { notice = blocker; phase = .failed; panel?.show(); return }
        text = ""; rawText = ""; meter = DictationMeter(); captureStarted = false; finishWhenReady = false
        notice = nil; target = nil; targetFrame = nil; hasWrittenToTarget = false; targetName = "预览"; delivered = false; deliveryConfirmed = false
        if !previewOnly {
            do {
                target = try capturedTarget ?? targetFactory(); targetName = target?.appName ?? "预览"; targetFrame = target?.anchorRect
            }
            catch { notice = String(describing: error); phase = .failed; panel?.show(); return }
        }
        let config: DictationConfiguration
        do {
            guard let configuration else { throw ProviderError(.permanent, "语音输入尚未配置。") }
            config = try configuration()
        } catch { notice = String(describing: error); phase = .failed; panel?.show(); return }
        generation = UUID(); let id = generation
        document = DictationDocument(); sessionConfig = config
        phase = .starting; panel?.show()
        let mic = captureFactory(), engine = config.recognizer
        capture = mic; recognizer = engine
        armTimeout(seconds: 25, id: id, message: "语音输入准备超时，请检查权限、模型或连接。")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if let blocker = await engine.availability(sourceLanguage: config.language).blocker { throw ProviderError(.userFixable, blocker) }
                try self.check(id)
                try await mic.prepare(AudioSourceDescriptor(kind: .microphone, deviceUID: config.microphoneID, displayName: "听写麦克风"))
                try self.check(id)
                let (packets, packetSink) = AsyncStream<AudioPacket>.makeStream(bufferingPolicy: .bufferingOldest(128))
                self.audioTask = Task { [weak self] in
                    defer { packetSink.finish() }
                    for await event in mic.events {
                        guard let self, self.generation == id, !Task.isCancelled else { return }
                        switch event {
                        case .packet(let packet):
                            if self.phase == .starting || self.phase == .listening { self.meter.consume(rms: packet.samples.energy().rms) }
                            if case .dropped = packetSink.yield(packet) {
                                self.fail("识别引擎启动或处理过慢，音频缓冲已满；请换用更快的模型。"); return
                            }
                        case .failed(let error): self.fail(error.message); return
                        case .stopped: return
                        case .gap: self.notice = "音频曾中断，请检查识别结果。"
                        default: break
                        }
                    }
                }
                self.captureStarted = true
                try await mic.start()
                try self.check(id)
                let stream = try await engine.start(RecognizerRequest(sessionID: id.uuidString, laneID: "dictation", providerEpoch: 1,
                    sourceLanguage: config.language, sourceKind: .microphone, vocabulary: config.vocabulary))
                try self.check(id)
                self.eventsTask = Task { [weak self] in
                    for await event in stream.events {
                        guard let self, !Task.isCancelled, self.generation == id else { return }
                        switch event {
                        case .chunk(let chunk): self.receive(chunk, config: config)
                        case .failed(let error): self.fail(error.message); return
                        }
                    }
                    if let self, self.generation == id, self.phase == .listening {
                        self.fail("识别连接提前结束，已保留当前文字。")
                    }
                }
                let converter = ResamplingFormatAdapter()
                self.forwardingTask = Task { [weak self] in
                    for await packet in packets {
                        guard let self, self.generation == id, !Task.isCancelled else { return }
                        await engine.push(converter.convert(packet, to: stream.inputFormat))
                    }
                }
                try self.check(id)
                self.watchdog?.cancel(); self.phase = .listening
                if self.finishWhenReady { self.finish(); return }
                self.lifetime = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    guard let self, self.generation == id, self.phase == .listening else { return }
                    self.notice = "已达到单次 5 分钟上限，正在收尾。"; self.finish()
                }
            } catch {
                await mic.stop(); await engine.cancel()
                if self.generation == id { self.fail(String(describing: error)) }
            }
        }
    }

    private func check(_ id: UUID) throws {
        guard generation == id, !Task.isCancelled else { throw CancellationError() }
    }

    private func receive(_ chunk: TranscriptChunk, config: DictationConfiguration) {
        document.receive(chunk)
        rawText = document.text
        let spelling = config.vocabulary.map { VocabularyTerm(source: $0, target: $0) }
        text = VocabularyMatcher(config.replacements + spelling).replacing(in: document.text)
        if config.liveInsertion, target?.supportsLiveInsertion == true { deliver() }
    }

    private func deliver() {
        guard let target, !text.isEmpty || hasWrittenToTarget else { return }
        do {
            if text.isEmpty {
                try target.restoreOriginalSelection()
                hasWrittenToTarget = false
            } else {
                try target.replace(with: text)
                hasWrittenToTarget = true
            }
            if settings.nearInput { targetFrame = target.anchorRect }
        }
        catch DictationInputError.hostFocused { return }
        catch { notice = String(describing: error); self.target = nil; targetName = "预览（已停止写入）" }
    }

    func finish() {
        guard phase == .listening, let mic = capture, let engine = recognizer, let config = sessionConfig else { return }
        phase = .finishing; meter = DictationMeter(); heldSource = nil; lifetime?.cancel()
        let id = generation
        armTimeout(seconds: 35, id: id, message: "识别或纠错收尾超时，已保留当前文字。")
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                await mic.stop()
                await self.audioTask?.value
                await self.forwardingTask?.value
                try self.check(id)
                try await engine.finish()
                await self.eventsTask?.value
                try self.check(id)
                if let corrector = config.corrector, !self.text.isEmpty {
                    self.phase = .correcting
                    do {
                        let corrected = try await corrector.correct(self.text, vocabulary: config.vocabulary)
                        try self.check(id)
                        self.text = VocabularyMatcher(config.replacements).replacing(in: corrected)
                    } catch {
                        try self.check(id)
                        self.notice = "完成纠错未成功，已保留识别原文。"
                    }
                }
                try self.check(id)
                if let target = self.target, !self.text.isEmpty {
                    let finalText = self.text
                    let delivery = Task { try await target.commit(finalText) }
                    self.deliveryTask = delivery
                    do {
                        try await delivery.value
                        try self.check(id)
                        self.delivered = true
                        self.deliveryConfirmed = target.canConfirmDelivery
                        if !self.deliveryConfirmed { self.notice = "已发送粘贴，请确认输入框中的文字。" }
                    }
                    catch {
                        try self.check(id)
                        self.notice = String(describing: error); self.target = nil
                    }
                    try self.check(id)
                    self.deliveryTask = nil
                } else { self.deliver() }
                self.watchdog?.cancel()
                await engine.cancel()
                try self.check(id)
                self.capture = nil; self.recognizer = nil; self.sessionConfig = nil
                self.phase = .completed; self.meter = DictationMeter()
                if self.text.isEmpty { self.notice = "未识别到语音。" }
                if self.deliveryConfirmed, self.notice == nil { self.panel?.dismissAfterSuccess() }
            } catch {
                if self.generation == id { self.fail(String(describing: error)) }
            }
        }
    }

    private func armTimeout(seconds: Double, id: UUID, message: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == id else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        cancel(hide: false)
        phase = .failed; notice = message
    }

    func cancel(hide: Bool = true, immediately: Bool = false) {
        generation = UUID()
        let mic = capture, engine = recognizer, delivery = deliveryTask
        operation?.cancel(); audioTask?.cancel(); forwardingTask?.cancel(); eventsTask?.cancel(); watchdog?.cancel(); lifetime?.cancel()
        delivery?.cancel(); deliveryTask = nil
        capture = nil; recognizer = nil; target = nil; sessionConfig = nil
        captureStarted = false; finishWhenReady = false; heldSource = nil; meter = DictationMeter(); delivered = false; deliveryConfirmed = false
        HotKeyCenter.shared.resetDictationModifier()
        phase = .idle
        if hide { panel?.hide(immediately: immediately) }
        guard mic != nil || engine != nil || delivery != nil else { return }
        cleaningUp = true
        Task { [weak self] in
            await mic?.stop(); await engine?.cancel()
            _ = try? await delivery?.value
            self?.cleaningUp = false
        }
    }

    func copyResult() {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "已复制"
    }

    func shutdown() {
        cancel(immediately: true)
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }
}
