import Foundation
import CryptoKit
import ZIPFoundation

enum ModuleInstaller {
    static let repository = "fantay0312/LiveLearn"
    static let maximumDownload: Int64 = 600 * 1_024 * 1_024
    static let maximumExpanded: Int64 = 1_500 * 1_024 * 1_024

    static func authenticatedCatalog(_ data: Data, publicKey: Data) throws -> ModuleCatalog {
        guard data.count < 1_024 * 1_024 else { throw ModuleInstallError.invalid("模块目录过大。") }
        let signed = try JSONDecoder().decode(SignedModuleCatalog.self, from: data)
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signed.signature, for: signed.payload) else {
            throw ModuleInstallError.invalid("模块目录签名无效，已停止下载。")
        }
        let catalog = try JSONDecoder().decode(ModuleCatalog.self, from: signed.payload)
        guard catalog.schema == 1, Set(catalog.modules.map(\.id)).count == catalog.modules.count else {
            throw ModuleInstallError.invalid("模块目录版本不兼容或存在重复项目。")
        }
        for artifact in catalog.modules { try validate(artifact) }
        return catalog
    }

    static func validate(_ artifact: ModuleArtifact) throws {
        guard artifact.apiVersion == 1,
              !artifact.version.isEmpty, artifact.version.count <= 64,
              artifact.version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }),
              !artifact.version.hasPrefix("."),
              artifact.sha256.count == 64, artifact.sha256.allSatisfy(\.isHexDigit),
              artifact.bytes > 0, artifact.bytes <= maximumDownload,
              artifact.expandedBytes > 0, artifact.expandedBytes <= maximumExpanded,
              artifact.minimumMacOS >= 15,
              ["arm64", "x86_64", "universal"].contains(artifact.architecture),
              isReleaseURL(artifact.url) else {
            throw ModuleInstallError.invalid("模块下载信息无效。")
        }
    }

    static func isReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil
            && url.path.hasPrefix("/\(repository)/releases/download/")
            && !url.pathComponents.contains("..")
    }

    static func safeArchivePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { $0 != ".." && $0 != "." }
    }

    static func unpack(_ zip: URL, artifact: ModuleArtifact, to destination: URL) throws {
        try validate(artifact)
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard Int64(data.count) == artifact.bytes,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == artifact.sha256.lowercased() else {
            throw ModuleInstallError.invalid("模块文件校验失败，请重新下载。")
        }
        let archive = try Archive(url: zip, accessMode: .read)
        var paths = Set<String>()
        var links: [(Entry, String)] = []
        var total: Int64 = 0
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 40_000, safeArchivePath(entry.path),
                  paths.insert(entry.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted else {
                throw ModuleInstallError.invalid("模块包含不安全的文件路径。")
            }
            if entry.type == .symlink {
                guard entry.uncompressedSize <= 4_096 else { throw ModuleInstallError.invalid("模块链接过长。") }
                var target = Data()
                let checksum = try archive.extract(entry) { target.append($0) }
                guard checksum == entry.checksum, let path = String(data: target, encoding: .utf8),
                      !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
                    throw ModuleInstallError.invalid("模块包含无效链接。")
                }
                let resolved = destination.appendingPathComponent(entry.path).deletingLastPathComponent()
                    .appendingPathComponent(path).standardizedFileURL
                guard resolved.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                    throw ModuleInstallError.invalid("模块链接超出安装目录。")
                }
                links.append((entry, path))
            }
            total += Int64(entry.uncompressedSize)
            guard total <= artifact.expandedBytes, total <= maximumExpanded else {
                throw ModuleInstallError.invalid("模块展开大小超过限制。")
            }
        }
        guard total == artifact.expandedBytes else { throw ModuleInstallError.invalid("模块文件清单大小不符。") }
        for (link, _) in links {
            guard !paths.contains(where: { $0.hasPrefix(link.path.lowercased() + "/") }) else {
                throw ModuleInstallError.invalid("模块文件不能写入链接目录。")
            }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in archive where entry.type != .symlink {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.path)
            let checksum = try archive.extract(entry, to: target)
            guard checksum == entry.checksum else { throw ModuleInstallError.invalid("模块文件校验失败。") }
        }
        for (entry, path) in links {
            let target = destination.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: path)
        }
        for (entry, _) in links {
            let target = destination.appendingPathComponent(entry.path)
            guard target.resolvingSymlinksInPath().path.hasPrefix(destination.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: target.path) else {
                throw ModuleInstallError.invalid("模块包含越界或失效的链接。")
            }
        }
        for path in artifact.id.requiredPaths {
            guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path) else {
                throw ModuleInstallError.invalid("模块缺少必要文件：\(path)")
            }
        }
        if artifact.id != .browserExtension {
            for path in artifact.id.requiredPaths where path.hasPrefix("Helpers/") {
                let executable = destination.appendingPathComponent(path)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                let verify = Process()
                verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verify.arguments = ["--verify", "--strict", executable.path]
                verify.standardError = FileHandle.nullDevice
                verify.standardOutput = FileHandle.nullDevice
                try verify.run()
                verify.waitUntilExit()
                guard verify.terminationStatus == 0 else { throw ModuleInstallError.invalid("模块代码签名校验失败。") }
            }
        }
    }
}
