import Foundation

/// One bounded transfer. Cancellation also reaches URLSession while it is waiting for data.
final class ModuleDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let limit: Int64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var failure: Error?

    private init(limit: Int64) { self.limit = limit }

    static func fetch(_ url: URL, limit: Int64) async throws -> URL {
        let download = ModuleDownload(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in download.start(url, continuation: continuation) }
        } onCancel: { download.cancel() }
    }

    private func start(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit {
            lock.withLock { failure = ModuleInstallError.invalid("下载大小超过预期，已停止。") }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw ModuleInstallError.invalid("模块下载暂不可用，请稍后重试。实时翻译仍可使用。")
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, Int64(size) <= limit else { throw ModuleInstallError.invalid("下载大小超过预期。") }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLearn-module-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination), session: session)
        } catch { finish(.failure(error), session: session) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error), session: session) }
    }

    private func finish(_ result: Result<URL, Error>, session: URLSession) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        let final: Result<URL, Error> = failure.map { .failure($0) } ?? (cancelled ? .failure(CancellationError()) : result)
        lock.unlock()
        if case .success(let url) = result, case .failure = final { try? FileManager.default.removeItem(at: url) }
        continuation?.resume(with: final)
        session.finishTasksAndInvalidate()
    }
}
