// Small blocking WebSocket client (Network.framework NWProtocolWebSocket) used by `bench`, the
// tests and the Adapter smoke checks. Also doubles as an interoperability check for the
// hand-rolled server: Network.framework produces real client-masked frames.
import Foundation
import Network
import TypelessCore

public final class LoopbackWSClient {
    public enum Kind: Equatable { case text, binary, close }

    public let url: URL
    private let queue = DispatchQueue(label: "typeless.wsclient")
    private var connection: NWConnection?
    private let lock = NSCondition()
    private var inbox: [(Kind, [UInt8])] = []
    private var failure: Error? = nil
    private var closed = false

    public init(url: URL) { self.url = url }

    public func connect(timeout: TimeInterval = 5) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let conn = NWConnection(to: .url(url), using: params)
        connection = conn
        let ready = DispatchSemaphore(value: 0)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                ready.signal()
                self.receiveLoop()
            case .failed(let err):
                self.lock.lock(); self.failure = err; self.closed = true; self.lock.broadcast(); self.lock.unlock()
                ready.signal()
            case .cancelled:
                self.lock.lock(); self.closed = true; self.lock.broadcast(); self.lock.unlock()
            default: break
            }
        }
        conn.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else { throw LiveTransportError("ws client connect timeout") }
        lock.lock(); let f = failure; lock.unlock()
        if let f = f { throw f }
    }

    private func receiveLoop() {
        guard let conn = connection else { return }
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            var kind: Kind? = nil
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text: kind = .text
                case .binary: kind = .binary
                case .close: kind = .close
                default: kind = nil // ping/pong: nothing to surface
                }
            } else if let c = content, !c.isEmpty {
                kind = .binary
            }
            self.lock.lock()
            if let kind = kind {
                self.inbox.append((kind, content.map { [UInt8]($0) } ?? []))
                if kind == .close { self.closed = true }
            }
            if let error = error {
                self.failure = error
                self.closed = true
            } else if isComplete && content == nil && kind == nil {
                self.closed = true
            }
            let stop = self.closed
            self.lock.broadcast()
            self.lock.unlock()
            if !stop { self.receiveLoop() }
        }
    }

    public func send(_ bytes: [UInt8], kind: Kind) {
        guard let conn = connection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: kind == .text ? .text : .binary)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [metadata])
        conn.send(content: Data(bytes), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    public func sendText(_ text: String) { send(Array(text.utf8), kind: .text) }
    public func sendBinary(_ bytes: [UInt8]) { send(bytes, kind: .binary) }

    /// Blocks until a message arrives; returns nil on timeout.
    public func receive(timeout: TimeInterval = 5) -> (Kind, [UInt8])? {
        let deadline = Date().addingTimeInterval(timeout)
        lock.lock()
        defer { lock.unlock() }
        while inbox.isEmpty {
            if closed && inbox.isEmpty { return nil }
            if !lock.wait(until: deadline) { return nil }
        }
        return inbox.removeFirst()
    }

    /// Receives text frames until one has `type == want` (or timeout); returns all seen events.
    public func receiveEvents(until want: String, timeout: TimeInterval = 10) -> [JSONValue] {
        var events: [JSONValue] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let (kind, payload) = receive(timeout: deadline.timeIntervalSinceNow) else { break }
            if kind == .close { break }
            guard kind == .text, let obj = try? JSONParser.parse(payload) else { continue }
            events.append(obj)
            if obj["type"] == .string(want) || obj["type"] == .string("error") { break }
        }
        return events
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }
}

/// Plain-HTTP GET over a fresh TCP connection (for /health and 404/501 checks).
public func httpGET(host: String, port: UInt16, path: String, timeout: TimeInterval = 5) throws -> (status: Int, body: [UInt8]) {
    let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "typeless.httpget")
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var collected: [UInt8] = []
    var failure: Error? = nil
    func readMore() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let d = data { lock.lock(); collected.append(contentsOf: d); lock.unlock() }
            if let e = error { lock.lock(); failure = e; lock.unlock(); done.signal(); return }
            if isComplete { done.signal(); return }
            readMore()
        }
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
            let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in })
            readMore()
        case .failed(let e):
            lock.lock(); failure = e; lock.unlock(); done.signal()
        default: break
        }
    }
    conn.start(queue: queue)
    defer { conn.cancel() }
    guard done.wait(timeout: .now() + timeout) == .success else { throw LiveTransportError("http timeout") }
    lock.lock(); defer { lock.unlock() }
    if let f = failure, collected.isEmpty { throw f }
    guard case .parsed(let head, let bodyStart) = parseHTTPHead(collected) else { throw LiveTransportError("bad http response") }
    // head.method holds "HTTP/1.1", head.target the status code for a response line.
    _ = head.method
    let status = Int(head.target) ?? 0
    return (status, Array(collected[bodyStart...]))
}
