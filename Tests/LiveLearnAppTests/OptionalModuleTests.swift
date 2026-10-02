import Foundation
import CryptoKit
import Testing
import ZIPFoundation
@testable import LiveLearnApp

@MainActor
struct OptionalModuleTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_VERIFY_RELEASE"] == "1"))
    func releaseArchivesMatchSignedCatalog() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let releases = repository.appendingPathComponent("build/releases")
        let trust = try JSONDecoder().decode(ModuleTrust.self, from: Data(contentsOf: repository.appendingPathComponent("Sources/LiveLearnApp/Resources/ModuleTrust.json")))
        let catalog = try ModuleInstaller.authenticatedCatalog(Data(contentsOf: releases.appendingPathComponent("catalog.json")), publicKey: trust.publicKey)
        #expect(Set(catalog.modules.map(\.id)) == Set(OptionalModule.allCases))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn-release-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for artifact in catalog.modules {
            try ModuleInstaller.unpack(releases.appendingPathComponent(artifact.url.lastPathComponent), artifact: artifact,
                                       to: root.appendingPathComponent(artifact.id.rawValue))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVELEARN_VERIFY_NETWORK"] == "1"))
    func publishedModulesInstallFromGitHub() async throws {
        let suite = "LiveLearn.testing.network.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn-network-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let library = ModuleLibrary(defaults: defaults, root: root)
        library.install(.browserExtension)
        library.cancel(.browserExtension)
        while library.activity[.browserExtension] != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!library.isEnabled(.browserExtension))
        #expect(library.installed.isEmpty)
        for module in OptionalModule.allCases {
            library.install(module)
            while library.activity[module] != nil { try await Task.sleep(for: .milliseconds(100)) }
            #expect(library.errors[module] == nil, "\(library.errors[module] ?? "")")
            #expect(library.isEnabled(module))
            #expect(library.directory(module) != nil)
        }
        let restored = ModuleLibrary(defaults: defaults, root: root)
        #expect(OptionalModule.allCases.allSatisfy { restored.isEnabled($0) })
    }

    @Test func freshInstallIsCoreOnlyAndOnboardingIsPersistent() throws {
        let suite = "LiveLearn.testing.modules.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.onboardingCompleted)
        #expect(!settings.onboardingSound)
        #expect(settings.modules.enabled.isEmpty)
        let clean = ModuleLibrary(defaults: defaults, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        clean.setEnabled(.dictation, true)
        #expect(!clean.isEnabled(.dictation))
        settings.onboardingCompleted = true
        settings.listenTargetLanguage = "ja"
        let restored = AppSettings(defaults: defaults)
        #expect(restored.onboardingCompleted)
        #expect(restored.listenTargetLanguage == "ja")
        restored.onboardingCompleted = false
        #expect(restored.listenTargetLanguage == "ja")
    }

    @Test func catalogRequiresPinnedSigningKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = try JSONEncoder().encode(ModuleCatalog(schema: 1, modules: []))
        let envelope = try JSONEncoder().encode(SignedModuleCatalog(payload: payload, signature: key.signature(for: payload)))
        #expect(try ModuleInstaller.authenticatedCatalog(envelope, publicKey: key.publicKey.rawRepresentation).modules.isEmpty)
        #expect(throws: (any Error).self) {
            try ModuleInstaller.authenticatedCatalog(envelope, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
        }
        let tampered = try JSONEncoder().encode(SignedModuleCatalog(payload: payload + Data([32]), signature: key.signature(for: payload)))
        #expect(throws: (any Error).self) { try ModuleInstaller.authenticatedCatalog(tampered, publicKey: key.publicKey.rawRepresentation) }
    }

    @Test func onlyThisRepositoryCanSupplyArtifacts() {
        #expect(ModuleInstaller.isReleaseURL(URL(string: "https://github.com/fantay0312/LiveLearn/releases/download/v1/browser.zip")!))
        for path in ["http://github.com/fantay0312/LiveLearn/releases/download/v1/browser.zip",
                     "https://github.com/other/LiveLearn/releases/download/v1/browser.zip",
                     "https://github.com.evil.test/fantay0312/LiveLearn/releases/download/v1/browser.zip",
                     "https://user@github.com/fantay0312/LiveLearn/releases/download/v1/browser.zip"] {
            #expect(!ModuleInstaller.isReleaseURL(URL(string: path)!))
        }
        for path in ["/etc/passwd", "../outside", "folder/../../outside", "folder\\outside", "folder/./item"] {
            #expect(!ModuleInstaller.safeArchivePath(path))
        }
        #expect(ModuleInstaller.safeArchivePath("BrowserExtension/package.json"))
    }

    @Test func validArchiveInstallsButHashMismatchAndTraversalFail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("test.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let bytes = Data("test".utf8)
        for path in OptionalModule.browserExtension.requiredPaths {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        let artifact = try artifact(zip: zip, expandedBytes: 8)
        let destination = root.appendingPathComponent("unpacked")
        try ModuleInstaller.unpack(zip, artifact: artifact, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("BrowserExtension/package.json").path))
        let wrong = ModuleArtifact(id: artifact.id, version: artifact.version, url: artifact.url,
                                   sha256: String(repeating: "0", count: 64), bytes: artifact.bytes,
                                   expandedBytes: 8, minimumMacOS: 15, architecture: "universal", apiVersion: 1)
        #expect(throws: (any Error).self) { try ModuleInstaller.unpack(zip, artifact: wrong, to: root.appendingPathComponent("wrong")) }
        try archive.addEntry(with: "../outside", type: .file, uncompressedSize: Int64(bytes.count)) { position, size in
            bytes.subdata(in: Int(position)..<Int(position) + size)
        }
        let unsafe = try self.artifact(zip: zip, expandedBytes: 12)
        #expect(throws: (any Error).self) { try ModuleInstaller.unpack(zip, artifact: unsafe, to: root.appendingPathComponent("unsafe")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside").path))
    }

    @Test func receiptsRequirePayloadAndUninstallRetainsOtherPreferences() throws {
        let suite = "LiveLearn.testing.modules.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn-test-\(UUID())")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let artifact = ModuleArtifact(id: .browserExtension, version: "1.0", url: URL(string: "https://github.com/fantay0312/LiveLearn/releases/download/v1/browser.zip")!, sha256: String(repeating: "a", count: 64), bytes: 20, expandedBytes: 30, minimumMacOS: 15, architecture: "universal", apiVersion: 1)
        let folder = root.appendingPathComponent("browserExtension")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(artifact).write(to: folder.appendingPathComponent("current.json"))
        defaults.set(["browserExtension"], forKey: "modules.enabled")
        #expect(!ModuleLibrary(defaults: defaults, root: root).isEnabled(.browserExtension))
        for path in OptionalModule.browserExtension.requiredPaths {
            let file = folder.appendingPathComponent("1.0/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("test".utf8).write(to: file)
        }
        let library = ModuleLibrary(defaults: defaults, root: root)
        #expect(library.isEnabled(.browserExtension))
        defaults.set("retained", forKey: "user.preference")
        library.remove(.browserExtension)
        #expect(!library.isEnabled(.browserExtension))
        #expect(library.installed.isEmpty)
        #expect(defaults.string(forKey: "user.preference") == "retained")
    }

    private func artifact(zip: URL, expandedBytes: Int64) throws -> ModuleArtifact {
        let data = try Data(contentsOf: zip)
        return ModuleArtifact(id: .browserExtension, version: "1.0", url: URL(string: "https://github.com/fantay0312/LiveLearn/releases/download/v1/browser.zip")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count), expandedBytes: expandedBytes, minimumMacOS: 15, architecture: "universal", apiVersion: 1)
    }
}
