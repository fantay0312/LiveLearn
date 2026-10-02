import Foundation
import WhisperKit

/// One Whisper model we offer. `id` is the folder name in the `argmaxinc/whisperkit-coreml`
/// repository on Hugging Face; sizes are the sum of the files in that folder (2026-09).
public struct WhisperVariant: Sendable, Identifiable, Equatable {
    public var id: String
    public var label: String
    public var sizeMB: Int
    public var note: String

    public static let all: [WhisperVariant] = [
        WhisperVariant(id: "openai_whisper-tiny", label: "tiny", sizeMB: 76, note: "最快，质量最低；试用或很弱的机器"),
        WhisperVariant(id: "openai_whisper-base", label: "base", sizeMB: 146, note: "快；英语可用，中日韩较差"),
        WhisperVariant(id: "openai_whisper-small", label: "small", sizeMB: 486, note: "速度与质量均衡"),
        WhisperVariant(id: "openai_whisper-large-v3-v20240930_626MB", label: "large-v3 压缩版", sizeMB: 626, note: "推荐：large-v3 的质量，体积最小，中日韩可用"),
        WhisperVariant(id: "openai_whisper-large-v3-v20240930_turbo", label: "large-v3 turbo", sizeMB: 1638, note: "比完整版快，质量接近"),
        WhisperVariant(id: "openai_whisper-large-v3", label: "large-v3", sizeMB: 3090, note: "最准，最慢，最占内存"),
    ]

    public static let defaultID = "openai_whisper-large-v3-v20240930_626MB"

    public static func named(_ id: String) -> WhisperVariant? { all.first { $0.id == id } }
    public static func label(for id: String) -> String { named(id)?.label ?? id }
}

/// Where the models live and how they get there. Every query is read-only; downloads and
/// deletions happen only through the explicit calls below.
public enum WhisperModelStore {
    public static let repo = "argmaxinc/whisperkit-coreml"

    /// `~/Library/Application Support/LiveLearn/Models/whisperkit`. WhisperKit's own default is
    /// `~/Documents/huggingface`, which is not where an app should keep gigabytes.
    public static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveLearn/Models/whisperkit", isDirectory: true)
    }

    /// The variant folder WhisperKit downloads into: `<base>/models/<repo>/<variant>`.
    public static func folder(for id: String) -> URL {
        downloadBase.appendingPathComponent("models/\(repo)/\(id)", isDirectory: true)
    }

    private static let requiredFiles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json"]

    public static func isInstalled(_ id: String) -> Bool {
        let dir = folder(for: id)
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    /// Bytes on disk for the settings screen ("已安装 · 626 MB").
    public static func installedBytes(_ id: String) -> Int64 {
        let dir = folder(for: id)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Variants WhisperKit's device table lists for this Mac; empty when the table has no entry.
    public static func supportedOnThisMac() -> Set<String> {
        Set(WhisperKit.recommendedModels().supported)
    }

    /// Downloads one variant from Hugging Face. Progress is 0…1.
    public static func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let base = downloadBase
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: id, downloadBase: base, useBackgroundSession: false, from: repo, progressCallback: { p in
            progress(p.fractionCompleted)
        })
    }

    /// Loads the model once: fetches the tokenizer (WhisperKit downloads it on first load even
    /// with downloads off) and lets CoreML compile for this machine, so the first session does
    /// not pay for either. The loaded model stays in the process cache.
    public static func prepare(_ id: String) async throws {
        let decoder = await WhisperDecoderCache.shared.decoder(for: id)
        try await decoder.load()
    }

    public static func delete(_ id: String) async throws {
        await WhisperDecoderCache.shared.evict(id)
        let dir = folder(for: id)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

/// Catalog codes are BCP-47 (`zh-Hans`); Whisper wants its own ISO list (`zh`).
public enum WhisperLanguage {
    public static func code(_ catalog: String) -> String {
        switch catalog {
        case "fil": return "tl"
        case "nb": return "no"
        default: return String(catalog.split(separator: "-").first ?? "").lowercased()
        }
    }

    public static func isSupported(_ catalog: String) -> Bool {
        Constants.languageCodes.contains(code(catalog))
    }
}
