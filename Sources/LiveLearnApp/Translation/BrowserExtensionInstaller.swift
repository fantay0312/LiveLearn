import AppKit
import CryptoKit
import Foundation

enum TranslationBrowser: String, CaseIterable, Identifiable, Sendable {
    case chrome, edge, brave, arc, chromium
    var id: String { rawValue }
    var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .arc: "Arc"
        case .chromium: "Chromium"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .brave: "com.brave.Browser"
        case .arc: "company.thebrowser.Browser"
        case .chromium: "org.chromium.Chromium"
        }
    }
    var managerURL: URL {
        URL(string: self == .edge ? "edge://extensions" : self == .brave ? "brave://extensions" : "chrome://extensions")!
    }
    @MainActor var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

struct BrowserExtensionPackage: Codable, Sendable {
    let version: String
    let upstreamCommit: String
    let extensionID: String
    let archiveSHA256: String
    let files: [String: String]

    static func read(from resources: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: resources.appendingPathComponent("package.json")))
    }

    /// Hash every shipped file, not only the manifest. Symlinks never cross the package boundary.
    func validate(directory: URL) throws {
        guard !files.isEmpty, files["manifest.json"] != nil else { throw BrowserExtensionError.invalidPackage }
        for (path, expected) in files {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw BrowserExtensionError.invalidPackage
            }
            let url = directory.appendingPathComponent(path)
            let root = directory.resolvingSymlinksInPath().path + "/"
            guard url.resolvingSymlinksInPath().path.hasPrefix(root),
                  try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  try Self.digest(url) == expected else { throw BrowserExtensionError.invalidPackage }
        }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        guard manifest?["version"] as? String == version, manifest?["manifest_version"] as? Int == 3,
              let key = manifest?["key"] as? String, let keyData = Data(base64Encoded: key) else {
            throw BrowserExtensionError.invalidPackage
        }
        let hex = SHA256.hash(data: keyData).prefix(16).map { String(format: "%02x", $0) }.joined()
        let id = hex.map { String(UnicodeScalar(97 + Int(String($0), radix: 16)!)!) }.joined()
        guard id == extensionID else { throw BrowserExtensionError.invalidPackage }
    }

    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}

enum BrowserExtensionError: LocalizedError {
    case missingPackage, invalidPackage, extractionFailed, browserMissing
    var errorDescription: String? {
        switch self {
        case .missingPackage: "此应用缺少网页翻译扩展，请使用完整构建的 LiveLearn。"
        case .invalidPackage: "扩展文件校验未通过，原有扩展已保留。请重新构建完整应用。"
        case .extractionFailed: "无法解压本地扩展，请检查磁盘空间和文件夹权限后重试。"
        case .browserMissing: "未找到所选浏览器。可先准备扩展文件，再到已安装的兼容浏览器中加载。"
        }
    }
}

/// Installs only bundled files. Browser permission and loading remain an explicit browser action.
enum BrowserExtensionFiles {
    static func install(resources: URL, destination: URL) throws -> BrowserExtensionPackage {
        let fm = FileManager.default
        let package = try BrowserExtensionPackage.read(from: resources)
        let archive = resources.appendingPathComponent("chromium.zip")
        guard try BrowserExtensionPackage.digest(archive) == package.archiveSHA256 else {
            throw BrowserExtensionError.invalidPackage
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".backup-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BrowserExtensionError.extractionFailed }
        try package.validate(directory: staging)
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if existed { try fm.moveItem(at: backup, to: destination) }
            throw error
        }
        // Browser settings live in browser storage under a stable extension ID, outside this directory.
        if existed { try? fm.removeItem(at: backup) }
        return package
    }
}

@MainActor @Observable
final class BrowserExtensionInstaller {
    private(set) var isPreparing = false
    private(set) var prepared = false
    private(set) var needsUpdate = false
    private(set) var error: String?
    private(set) var message: String?
    let resources: URL?
    let destination: URL
    let package: BrowserExtensionPackage?

    init(resources: URL? = ModuleLibrary.shared.directory(.browserExtension)?.appendingPathComponent("BrowserExtension"),
         destination: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveLearn/BrowserExtensions/LiveLearn")) {
        self.resources = resources
        self.destination = destination
        package = resources.flatMap { try? BrowserExtensionPackage.read(from: $0) }
        // Same upstream version can contain a new LiveLearn revision. Check the actual files.
        // Preparation still never means that a browser has enabled the extension.
        if let package, FileManager.default.fileExists(atPath: destination.path) {
            prepared = (try? package.validate(directory: destination)) != nil
            needsUpdate = !prepared
        }
    }

    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        error = nil
        message = nil
        defer { isPreparing = false }
        guard let resources, package != nil else { error = BrowserExtensionError.missingPackage.localizedDescription; return }
        let destination = destination
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try BrowserExtensionFiles.install(resources: resources, destination: destination)
            }.value
            prepared = true
            needsUpdate = false
            message = "文件已准备。请在浏览器中加载此文件夹；更新后点击扩展的重新加载按钮。"
        } catch { self.error = error.localizedDescription }
    }

    func openManager(_ browser: TranslationBrowser) { open(browser.managerURL, in: browser) }
    func openOptions(_ browser: TranslationBrowser) {
        guard let package else { return }
        open(URL(string: "chrome-extension://\(package.extensionID)/options.html")!, in: browser)
    }
    private func open(_ url: URL, in browser: TranslationBrowser) {
        guard let application = browser.applicationURL else { error = BrowserExtensionError.browserMissing.localizedDescription; return }
        error = nil
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            if let error { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting([destination.appendingPathComponent("manifest.json")]) }
    func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(destination.path, forType: .string)
        message = "扩展路径已复制。选择文件夹时按 ⇧⌘G，粘贴路径即可。"
    }
    func showSource() {
        guard let resources else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resources.appendingPathComponent("ReadFrog-source.tar.gz")])
    }
}
