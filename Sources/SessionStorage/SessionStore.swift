import Foundation

public enum SessionStoreError: Error, CustomStringConvertible {
    case notFound(String)
    case write(String, underlying: String)
    case read(String, underlying: String)

    public var description: String {
        switch self {
        case .notFound(let id): return "找不到记录 \(id)"
        case .write(let path, let underlying): return "写入失败：\(path)（\(underlying)）"
        case .read(let path, let underlying): return "读取失败：\(path)（\(underlying)）"
        }
    }
}

/// One JSON file per session in a folder the user can open. Writes are atomic (temporary file
/// then rename), so a crash or a full disk never leaves a half-written record behind. A running
/// session may be checkpointed to `<id>.inprogress.json`; on the next launch that file becomes a
/// record marked "interrupted".
public final class SessionStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/LiveLearn/Sessions
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LiveLearn/Sessions", isDirectory: true)
    }

    public func url(for id: String) -> URL {
        directory.appendingPathComponent("\(Self.safe(id)).json")
    }

    func checkpointURL(for id: String) -> URL {
        directory.appendingPathComponent("\(Self.safe(id)).inprogress.json")
    }

    private static func safe(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    /// ISO 8601 with fractional seconds: readable in the file, exact on the way back.
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(dateStyle))
        }
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? dateStyle.parse(s) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
        }
        return d
    }()

    // MARK: - Records

    @discardableResult
    public func save(_ archive: SessionArchive) throws -> URL {
        let url = self.url(for: archive.id)
        try writeAtomically(archive, to: url)
        return url
    }

    public func load(id: String) throws -> SessionArchive {
        let url = self.url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SessionStoreError.notFound(id) }
        return try read(url)
    }

    /// Every readable record, newest first. Unreadable files are skipped and reported.
    public func loadAll() -> (archives: [SessionArchive], problems: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return ([], []) }
        var out: [SessionArchive] = []
        var problems: [String] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".inprogress.json") {
            let url = directory.appendingPathComponent(name)
            do {
                out.append(try read(url))
            } catch {
                problems.append("\(name)：\(error)")
            }
        }
        out.sort { $0.startedAt > $1.startedAt }
        return (out, problems)
    }

    public func delete(id: String) throws {
        let url = self.url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SessionStoreError.write(url.path, underlying: "\(error)")
        }
    }

    public func exists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    // MARK: - Checkpoints

    public func writeCheckpoint(_ archive: SessionArchive) throws {
        var a = archive
        a.outcome = .interrupted
        a.endedAt = nil
        try writeAtomically(a, to: checkpointURL(for: archive.id))
    }

    public func clearCheckpoint(id: String) {
        try? FileManager.default.removeItem(at: checkpointURL(for: id))
    }

    /// Turns leftover checkpoints into records (outcome `.interrupted`) and removes them.
    /// A checkpoint whose final record already exists is simply discarded.
    public func recoverCheckpoints() -> [SessionArchive] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var recovered: [SessionArchive] = []
        for name in names where name.hasSuffix(".inprogress.json") {
            let url = directory.appendingPathComponent(name)
            guard var archive = try? read(url) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if exists(id: archive.id) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            archive.outcome = .interrupted
            if !archive.isEmpty, (try? save(archive)) != nil {
                recovered.append(archive)
            }
            try? FileManager.default.removeItem(at: url)
        }
        return recovered
    }

    // MARK: - Export

    @discardableResult
    public func export(_ archive: SessionArchive, format: ExportFormat, to url: URL) throws -> URL {
        let text = try TranscriptExporter.render(archive, format: format)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            throw SessionStoreError.write(url.path, underlying: "\(error)")
        }
        return url
    }

    // MARK: - IO

    private func writeAtomically(_ archive: SessionArchive, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SessionStoreError.write(url.path, underlying: "\(error)")
        }
    }

    private func read(_ url: URL) throws -> SessionArchive {
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(SessionArchive.self, from: data)
        } catch {
            throw SessionStoreError.read(url.path, underlying: "\(error)")
        }
    }
}
