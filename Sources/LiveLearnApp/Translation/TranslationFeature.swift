import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct TranslationVocabularyDraft: Equatable, Identifiable {
    let id = UUID()
    var source: String
    var target: String
}

struct TranslationReply: Decodable, Sendable {
    var id: String?
    var ok: Bool
    var error: String?
    var event: String?
    var protocolVersion: Int?
    var services: [String]?
    var languages: Int?
    var windows: [String]?
    var source: String?
    var translation: String?
    var settingsPage: String?
    var settingsSection: Int?
}

private struct TranslationCommand: Encodable {
    var id: String
    var action: String
    var text: String?
    var dark: Bool?
    var targetPID: Int32?
    var settingsSection: Int?
}

enum TranslationFeatureError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// Owns the bundled translation helper and its private, inherited command pipes.
/// No global IPC name, network endpoint, shared command file or separate app install.
@MainActor
@Observable
final class TranslationFeature {
    static let shared = TranslationFeature()
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var openingActions: Set<String> = []
    @ObservationIgnored private var retryOperation: (action: String, text: String?, dark: Bool?)?
    private(set) var serviceCount = 0
    @ObservationIgnored var onVocabularyDraft: (@MainActor (TranslationVocabularyDraft) -> Void)?
    @ObservationIgnored var onSettingsNavigation: (@MainActor (TranslationReply) -> Void)?
    @ObservationIgnored var onExit: (@MainActor () -> Void)?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: Pipe?
    @ObservationIgnored private var output: Pipe?
    @ObservationIgnored private var framer = TranslationReplyFramer(token: UUID().uuidString)
    @ObservationIgnored private var pending: [String: CheckedContinuation<TranslationReply, Error>] = [:]
    @ObservationIgnored private var timeouts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let writer = DispatchQueue(label: "LiveLearn.translation.commands")
    private let enabledKey = "LiveLearn.translationFeature.enabled"
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var lastExternalPID: Int32?

    private init() {
        rememberExternalApp(NSWorkspace.shared.frontmostApplication)
        foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.rememberExternalApp(application) }
        }
    }

    private func rememberExternalApp(_ application: NSRunningApplication?) {
        guard let application,
              application.bundleIdentifier?.hasPrefix("com.fantasy.livelearn") != true else { return }
        lastExternalPID = application.processIdentifier
    }

    func chooseImage(dark: Bool? = nil) {
        let panel = NSOpenPanel()
        panel.title = "翻译图片中的文字"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("image", text: url.path, dark: dark)
    }

    func reviewCurrentResult(in model: AppModel) {
        Task {
            do {
                let result = try await request("result")
                guard let source = result.source, let target = result.translation else { return }
                model.translationVocabularyDraft = .init(source: source, target: target)
                model.requestVocabularyWindow()
            } catch {
                lastError = "无法读取当前译文：\(error.localizedDescription)"
                retryOperation = nil
            }
        }
    }

    func perform(_ action: String, text: String? = nil, dark: Bool? = nil) {
        guard ModuleLibrary.shared.isEnabled(.textTranslation) else {
            UnifiedSettingsPresentation.shared.showTranslation()
            return
        }
        let isPresentation = ["workbench", "settings", "favorites", "showMiniWindow"].contains(action)
        if isPresentation {
            guard !openingActions.contains(action) else { return }
            openingActions.insert(action)
        }
        Task {
            defer { if isPresentation { openingActions.remove(action) } }
            do {
                if let dark { _ = try await request("theme", dark: dark) }
                _ = try await request(action, text: text)
                lastError = nil
                retryOperation = nil
            } catch {
                lastError = error.localizedDescription
                retryOperation = (action, text, dark)
            }
        }
    }

    var canRetry: Bool { retryOperation != nil }
    func dismissError() { lastError = nil; retryOperation = nil }
    func retryLastOperation() {
        guard let operation = retryOperation else { return }
        lastError = nil
        perform(operation.action, text: operation.text, dark: operation.dark)
    }

    func resumeIfEnabled() {
        guard ModuleLibrary.shared.isEnabled(.textTranslation), UserDefaults.standard.bool(forKey: enabledKey),
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--render") || $0 == "--probe" || $0 == "--preferences-suite" }) else { return }
        Task {
            do { _ = try await request("status") }
            catch { lastError = error.localizedDescription }
        }
    }

    func request(_ action: String, text: String? = nil, dark: Bool? = nil,
                 settingsSection: Int? = nil) async throws -> TranslationReply {
        try ensureRunning()
        guard pending.count < 32, let handle = input?.fileHandleForWriting else {
            throw TranslationFeatureError.unavailable("翻译操作较多，请稍候再试。")
        }
        let id = UUID().uuidString
        let needsSelection = ["selectTranslate", "translateAndReplace", "polishAndReplace"].contains(action)
        let command = TranslationCommand(id: id, action: action, text: text, dark: dark,
                                         targetPID: needsSelection ? lastExternalPID : nil,
                                         settingsSection: settingsSection)
        var data = try JSONEncoder().encode(command)
        guard data.count < 1_048_576 else {
            throw TranslationFeatureError.unavailable("文字过长，请分段翻译。")
        }
        data.append(10)
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                self?.finish(id, result: .failure(TranslationFeatureError.unavailable("翻译模块响应超时，请重试。")))
            }
            let payload = data
            writer.async { [weak self] in
                do { try handle.write(contentsOf: payload) }
                catch {
                    Task { @MainActor in self?.finish(id, result: .failure(error)) }
                }
            }
        }
        guard reply.ok else { throw TranslationFeatureError.unavailable(reply.error ?? "翻译操作没有完成。") }
        return reply
    }

    func shutdown() {
        // Closing the sole writer is the helper's shutdown signal, including host crashes.
        try? input?.fileHandleForWriting.close()
        input = nil
        failPending("LiveLearn 正在关闭。")
    }

    private func ensureRunning() throws {
        guard let directory = ModuleLibrary.shared.directory(.textTranslation) else {
            throw TranslationFeatureError.unavailable("请先在设置中安装并启用文字翻译。")
        }
        if process?.isRunning == true { return }
        if process != nil {
            failPending("上一次翻译进程已退出，请重试该操作。")
            output?.fileHandleForReading.readabilityHandler = nil
            try? input?.fileHandleForWriting.close()
        }
        let helpers = directory.appendingPathComponent("Helpers")
        let helper = helpers.appendingPathComponent("LiveLearnTranslation.app/Contents/MacOS/LiveLearnTranslation")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw TranslationFeatureError.unavailable("文字翻译模块文件缺失，请在功能管理中重新安装。")
        }
        let child = Process()
        let commandPipe = Pipe()
        let responsePipe = Pipe()
        child.executableURL = helper
        child.arguments = ["--livelearn-embedded"]
        let token = UUID().uuidString
        var environment = ProcessInfo.processInfo.environment
        environment["LIVELEARN_TRANSLATION_CHANNEL"] = token
        child.environment = environment
        child.standardInput = commandPipe
        child.standardOutput = responsePipe
        // Provider diagnostics stay in the helper's local log, not in the host protocol.
        child.standardError = FileHandle.nullDevice
        let generation = UUID()
        activeGeneration = generation
        responsePipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard self?.activeGeneration == generation else { return }
                self?.receive(data)
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard self?.activeGeneration == generation else { return }
                self?.isRunning = false
                self?.failPending("翻译模块已退出，请重新打开翻译工作台。")
                self?.output?.fileHandleForReading.readabilityHandler = nil
                self?.process = nil
                self?.input = nil
                self?.output = nil
                self?.onExit?()
            }
        }
        do { try child.run() }
        catch {
            responsePipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        try? commandPipe.fileHandleForReading.close()
        try? responsePipe.fileHandleForWriting.close()
        // Prevent a helper crash between the liveness check and a write from delivering
        // SIGPIPE to LiveLearn's audio/session process.
        _ = fcntl(commandPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        input = commandPipe
        output = responsePipe
        framer = TranslationReplyFramer(token: token)
        isRunning = true
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    @ObservationIgnored private var activeGeneration = UUID()

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        let replies: [TranslationReply]
        do { replies = try framer.append(data) }
        catch { failPending(error.localizedDescription); return }
        for reply in replies {
            if reply.event == "ready", reply.protocolVersion != 1 {
                failPending("翻译模块版本不兼容，请重新安装完整的 LiveLearn。")
                shutdown()
                return
            }
            if let services = reply.services { serviceCount = services.count }
            if reply.event == "vocabulary", let source = reply.source, let target = reply.translation {
                onVocabularyDraft?(.init(source: source, target: target))
            }
            if reply.event == "settingsNavigation" || reply.event == "settingsClosed" {
                onSettingsNavigation?(reply)
            }
            if let id = reply.id { finish(id, result: .success(reply)) }
        }
    }

    private func finish(_ id: String, result: Result<TranslationReply, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(_ message: String) {
        for id in Array(pending.keys) {
            finish(id, result: .failure(TranslationFeatureError.unavailable(message)))
        }
    }
}
