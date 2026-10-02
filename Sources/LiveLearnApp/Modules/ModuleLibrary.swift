import Foundation
import Observation

@MainActor @Observable
final class ModuleLibrary {
    static var shared = ModuleLibrary()
    static let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LiveLearn/Modules", isDirectory: true)
    private(set) var installed: [OptionalModule: ModuleArtifact] = [:]
    private(set) var enabled: Set<OptionalModule>
    private(set) var activity: [OptionalModule: String] = [:]
    private(set) var errors: [OptionalModule: String] = [:]
    private(set) var catalog: [OptionalModule: ModuleArtifact] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let root: URL
    @ObservationIgnored private var tasks: [OptionalModule: Task<Void, Never>] = [:]

    init(defaults: UserDefaults = .standard, root: URL = ModuleLibrary.defaultRoot) {
        self.defaults = defaults
        self.root = root
        enabled = Set((defaults.stringArray(forKey: "modules.enabled") ?? []).compactMap(OptionalModule.init))
        for module in OptionalModule.allCases {
            let receipt = root.appendingPathComponent("\(module.rawValue)/current.json")
            if let data = try? Data(contentsOf: receipt),
               let artifact = try? JSONDecoder().decode(ModuleArtifact.self, from: data),
               artifact.id == module, (try? ModuleInstaller.validate(artifact)) != nil {
                let directory = root.appendingPathComponent("\(module.rawValue)/\(artifact.version)")
                if module.requiredPaths.allSatisfy({ FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    installed[module] = artifact
                }
            }
        }
    }

    func isEnabled(_ module: OptionalModule) -> Bool { enabled.contains(module) && installed[module] != nil }

    func directory(_ module: OptionalModule) -> URL? {
        guard isEnabled(module), let version = installed[module]?.version else { return nil }
        return root.appendingPathComponent("\(module.rawValue)/\(version)")
    }

    func setEnabled(_ module: OptionalModule, _ value: Bool) {
        if value && installed[module] != nil { enabled.insert(module) } else { enabled.remove(module) }
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: "modules.enabled")
    }

    func install(_ module: OptionalModule) {
        guard tasks[module] == nil else { return }
        if installed[module] != nil { setEnabled(module, true); return }
        errors[module] = nil
        activity[module] = "获取下载信息…"
        tasks[module] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[module] = nil; self.activity[module] = nil }
            var temporary: URL?
            var staging: URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                if let staging { try? FileManager.default.removeItem(at: staging) }
            }
            do {
                guard let trustURL = Bundle.module.url(forResource: "ModuleTrust", withExtension: "json") else {
                    throw ModuleInstallError.invalid("此版本缺少可信模块目录。")
                }
                let trust = try JSONDecoder().decode(ModuleTrust.self, from: Data(contentsOf: trustURL))
                guard ModuleInstaller.isReleaseURL(trust.catalogURL) else { throw ModuleInstallError.invalid("模块目录地址无效。") }
                let catalogFile = try await ModuleDownload.fetch(trust.catalogURL, limit: 1_024 * 1_024)
                defer { try? FileManager.default.removeItem(at: catalogFile) }
                let data = try Data(contentsOf: catalogFile)
                let catalog = try ModuleInstaller.authenticatedCatalog(data, publicKey: trust.publicKey)
                self.catalog = Dictionary(uniqueKeysWithValues: catalog.modules.map { ($0.id, $0) })
                guard let artifact = self.catalog[module] else { throw ModuleInstallError.invalid("此模块尚未发布。") }
                #if arch(arm64)
                let architecture = "arm64"
                #else
                let architecture = "x86_64"
                #endif
                guard artifact.minimumMacOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                      [architecture, "universal"].contains(artifact.architecture) else {
                    throw ModuleInstallError.invalid("此模块尚不支持当前 macOS 版本或芯片。")
                }
                self.activity[module] = "正在下载 \(ByteCountFormatter.string(fromByteCount: artifact.bytes, countStyle: .file))…"
                let download = try await ModuleDownload.fetch(artifact.url, limit: artifact.bytes)
                temporary = download
                try Task.checkCancellation()
                self.activity[module] = "校验并安装…"
                let parent = self.root.appendingPathComponent(module.rawValue, isDirectory: true)
                let stage = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
                staging = stage
                let unpack = Task.detached(priority: .userInitiated) {
                    try ModuleInstaller.unpack(download, artifact: artifact, to: stage)
                }
                try await withTaskCancellationHandler { try await unpack.value } onCancel: { unpack.cancel() }
                try Task.checkCancellation()
                let destination = parent.appendingPathComponent(artifact.version, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: stage, to: destination)
                try JSONEncoder().encode(artifact).write(to: parent.appendingPathComponent("current.json"), options: .atomic)
                self.installed[module] = artifact
                self.setEnabled(module, true)
            } catch is CancellationError {
                self.errors[module] = nil
            } catch {
                self.errors[module] = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    func cancel(_ module: OptionalModule) { tasks[module]?.cancel() }

    func remove(_ module: OptionalModule) {
        guard tasks[module] == nil else { return }
        setEnabled(module, false)
        do {
            let folder = root.appendingPathComponent(module.rawValue)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            installed[module] = nil
            errors[module] = nil
        } catch { errors[module] = error.localizedDescription }
    }
}
