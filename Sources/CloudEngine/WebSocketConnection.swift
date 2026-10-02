import Foundation
import os
import ProviderAdapters

private let log = Logger(subsystem: "com.fantasy.livelearn", category: "websocket")

/// One WebSocket, owned by a recognizer session: sends are serialized, receives are a loop
/// (URLSession's `receive()` is single-shot), and the close code and reason, which never reach
/// `receive()`, are captured by the delegate so a bad key or a rejected model is explained
/// rather than seen as a silent stop.
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Message: Sendable {
        case text(String)
        case data(Data)
    }

    enum Close: Sendable, Equatable {
        case code(Int, reason: String)
        case error(String)
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var opened = false
    private var closed: Close?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private let sendQueue = DispatchQueue(label: "LiveLearn.ws.send")
    /// The HTTP status of the handshake, when the server answered with one.
    var handshakeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    init(request: URLRequest, maximumMessageSize: Int = 4 * 1024 * 1024) {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        // The delegate is set after `super.init`; the session holds it strongly until invalidated.
        let holder = DelegateHolder()
        session = URLSession(configuration: config, delegate: holder, delegateQueue: delegateQueue)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        super.init()
        holder.target = self
    }

    /// Opens the socket; throws when the handshake fails (with the HTTP status when there is one).
    func open() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { openContinuation = c }
            task.resume()
        }
    }

    func send(_ message: Message) async throws {
        let m: URLSessionWebSocketTask.Message
        switch message {
        case .text(let s): m = .string(s)
        case .data(let d): m = .data(d)
        }
        try await task.send(m)
    }

    /// The next message, or nil once the socket is closed.
    func receive() async -> Message? {
        do {
            switch try await task.receive() {
            case .string(let s): return .text(s)
            case .data(let d): return .data(d)
            @unknown default: return nil
            }
        } catch {
            lock.withLock { if closed == nil { closed = .error(error.localizedDescription) } }
            return nil
        }
    }

    func ping() {
        task.sendPing { error in
            if let error { log.notice("ping failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    var closeInfo: Close? { lock.withLock { closed } }

    func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        task.cancel(with: code, reason: nil)
        session.finishTasksAndInvalidate()
    }

    // MARK: - Delegate

    fileprivate func didOpen() {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            opened = true
            let c = openContinuation
            openContinuation = nil
            return c
        }
        c?.resume()
    }

    fileprivate func didClose(code: Int, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        log.notice("websocket closed code=\(code, privacy: .public) reason=\(text, privacy: .public)")
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            closed = .code(code, reason: text)
            let c = openContinuation
            openContinuation = nil
            return c
        }
        c?.resume(throwing: ProviderError(.retryable, "连接在握手时被关闭（\(code)）\(text.isEmpty ? "" : "：\(text)")"))
    }

    fileprivate func didComplete(error: Error?) {
        let status = handshakeStatus
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            if closed == nil, let error { closed = .error(error.localizedDescription) }
            let c = openContinuation
            openContinuation = nil
            return c
        }
        guard let c else { return }
        if let status, status >= 400 {
            c.resume(throwing: HTTPFailure.classify(status: status, body: Data(), service: "服务器"))
        } else {
            c.resume(throwing: ProviderError(.retryable, "无法建立连接：\(error?.localizedDescription ?? "未知错误")"))
        }
    }

    /// URLSession retains its delegate; this thin object breaks the cycle with the connection.
    private final class DelegateHolder: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        weak var target: WebSocketConnection?
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            target?.didOpen()
        }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            target?.didClose(code: closeCode.rawValue, reason: reason)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            target?.didComplete(error: error)
        }
    }
}
