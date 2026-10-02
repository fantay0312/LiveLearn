import Foundation
import CloudEngine

/// A fresh, lossless local backup on every click. No existing backup is overwritten.
enum VocabularyBackupStore {
    static func save(_ library: VocabularyLibrary, directory: URL? = nil) throws -> URL {
        let folder: URL
        if let directory {
            folder = directory
        } else {
            folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
                .appendingPathComponent("LiveLearn/VocabularyBackups", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "LiveLearn-词汇-\(date.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
        let url = folder.appendingPathComponent(name)
        try library.exportData().write(to: url, options: .atomic)
        return url
    }
}
