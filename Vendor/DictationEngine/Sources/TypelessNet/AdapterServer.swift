// Loopback GET /health + WS /asr Adapter on NWListener with a hand-rolled HTTP/1.1 + RFC 6455
// server. One serial queue per client connection hosts the client socket, the upstream
// (mock or live) transport and the engine, so PCM-in → encode → upstream-send and
// upstream-recv → event → client-send never hop threads or take locks.
import Foundation
import Network
import TypelessCore

public typealias TransportFactory = (DispatchQueue) throws -> ASRTransport

public struct AdapterServerError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class AdapterServer {
    public let host: String
    public let requestedPort: UInt16
    public let profile: ASRProfile
    public let live: Bool
    public let finishMode: FinishMode
    public private(set) var boundPort: UInt16 = 0
    public var log: ((String) -> Void)?
    private let transportFactory: TransportFactory
    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "typeless.adapter.listener", qos: .userInteractive)
    private var connections: [ObjectIdentifier: AdapterHTTPConnection] = [:]
    private let connectionsLock = NSLock()
    private var connectionSeq = 0

    public init(host: String = defaultListenHost, port: UInt16 = defaultListenPort, profile: ASRProfile = ASRProfile(),
                live: Bool = false, finishMode: FinishMode = .pending, transportFactory: TransportFactory? = nil) throws {
        self.host = try validateListenHost(host)
        self.requestedPort = port
        self.profile = profile
        self.live = live
        self.finishMode = finishMode
        if let f = transportFactory {
            self.transportFactory = f
        } else if live {
            self.transportFactory = { queue in LiveTransport(profile: profile, queue: queue) }
        } else {
            self.transportFactory = { _ in MockTransport() }
        }
    }

    public var url: String { "http://\(host):\(boundPort)" }

    /// Binds and blocks until the listener is ready (or fails).
    public func start(timeout: TimeInterval = 5) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.serviceClass = .responsiveData
        guard let port = NWEndpoint.Port(rawValue: requestedPort) else { throw AdapterServerError("bad port") }
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        let listener = try NWListener(using: params)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error? = nil
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let err):
                lock.lock(); failure = err; lock.unlock()
                ready.signal()
            case .cancelled:
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: listenerQueue)
        guard ready.wait(timeout: .now() + timeout) == .success else { throw AdapterServerError("listener start timeout") }
        lock.lock(); let f = failure; lock.unlock()
        if let f = f { throw AdapterServerError("listen failed: \(f)") }
    }

    private func accept(_ nw: NWConnection) {
        connectionSeq += 1
        let queue = DispatchQueue(label: "typeless.adapter.conn.\(connectionSeq)", qos: .userInteractive)
        let conn = AdapterHTTPConnection(connection: nw, queue: queue, profile: profile, live: live, finishMode: finishMode,
                                         transportFactory: transportFactory, log: log)
        let id = ObjectIdentifier(conn)
        connectionsLock.lock(); connections[id] = conn; connectionsLock.unlock()
        conn.onClosed = { [weak self] in
            guard let self = self else { return }
            self.connectionsLock.lock(); self.connections.removeValue(forKey: id); self.connectionsLock.unlock()
        }
        conn.start()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connectionsLock.lock(); let all = Array(connections.values); connections.removeAll(); connectionsLock.unlock()
        for c in all { c.queue.async { c.shutdown() } }
    }

    public var activeConnections: Int {
        connectionsLock.lock(); defer { connectionsLock.unlock() }
        return connections.count
    }
}

/// One accepted TCP connection: HTTP head → /health | /asr upgrade | 501 | 404.
final class AdapterHTTPConnection {
    let connection: NWConnection
    let queue: DispatchQueue
    let profile: ASRProfile
    let live: Bool
    let finishMode: FinishMode
    let transportFactory: TransportFactory
    let log: ((String) -> Void)?
    var onClosed: (() -> Void)?

    private var inbound: [UInt8] = []
    private var upgraded = false
    private var parser: WSFrameParser? = nil
    private var adapter: AdapterConnection? = nil
    private var startSeen = false
    private var closing = false
    private var terminated = false
    private var inactivity: DispatchSourceTimer? = nil
    private var finishTimer: DispatchSourceTimer? = nil

    init(connection: NWConnection, queue: DispatchQueue, profile: ASRProfile, live: Bool, finishMode: FinishMode,
         transportFactory: @escaping TransportFactory, log: ((String) -> Void)?) {
        self.connection = connection
        self.queue = queue
        self.profile = profile
        self.live = live
        self.finishMode = finishMode
        self.transportFactory = transportFactory
        self.log = log
        inbound.reserveCapacity(16 * 1024)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled:
                self.shutdown()
            default: break
            }
        }
        connection.start(queue: queue)
        armInactivityTimer()
        receive()
    }

    private func armInactivityTimer() {
        inactivity?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + finalTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.closing else { return }
            if self.upgraded, let adapter = self.adapter, !adapter.terminalSent {
                adapter.handleFailure("timeout waiting for client frame")
            } else {
                self.shutdown()
            }
        }
        timer.resume()
        inactivity = timer
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.terminated else { return }
            if let data = data, !data.isEmpty {
                if self.closing {
                    // Wait for the peer's close acknowledgement instead of resetting TCP while
                    // its WebSocket stack is still draining the final transcript.
                    let messages = data.withUnsafeBytes { try? self.parser?.feed($0) }
                    if messages?.contains(where: { if case .close = $0 { return true }; return false }) == true {
                        self.shutdown(); return
                    }
                } else {
                    self.armInactivityTimer()
                    data.withUnsafeBytes { self.handleBytes($0) }
                }
            }
            if error != nil || isComplete {
                self.handleClientGone()
                return
            }
            if !self.terminated { self.receive() }
        }
    }

    private func handleBytes(_ raw: UnsafeRawBufferPointer) {
        if upgraded {
            handleWSBytes(raw)
            return
        }
        inbound.append(contentsOf: raw)
        switch parseHTTPHead(inbound) {
        case .incomplete:
            return
        case .tooLarge:
            sendHTTP(status: 413, code: "payload_too_large", message: "HTTP headers too large")
        case .parsed(let head, let bodyStart):
            let rest = Array(inbound[bodyStart...])
            inbound.removeAll(keepingCapacity: false)
            route(head, rest: rest)
        }
    }

    private func route(_ head: HTTPRequestHead, rest: [UInt8]) {
        let path = head.path
        if head.method == "GET" && path == "/health" {
            let body = healthPayload().compactJSONBytes()
            sendAndClose(buildHTTPResponse(status: 200, reason: "OK", body: body))
            return
        }
        if head.method == "GET" && path == "/asr" {
            guard let key = head.headers["sec-websocket-key"], !key.isEmpty else {
                sendHTTP(status: 400, code: "invalid_request", message: "missing Sec-WebSocket-Key"); return
            }
            guard head.headers["upgrade"]?.lowercased() == "websocket" else {
                sendHTTP(status: 400, code: "invalid_request", message: "missing Upgrade: websocket"); return
            }
            upgraded = true
            parser = WSFrameParser(maxMessageSize: maxStartJSON + 64 * 1024)
            setupAdapter()
            connection.send(content: Data(buildHandshakeResponse(secKey: key)), completion: .contentProcessed { _ in })
            if !rest.isEmpty { rest.withUnsafeBytes { handleWSBytes($0) } }
            return
        }
        if unimplementedRoutes.contains(path) || path.hasPrefix("/candidate/") {
            sendHTTP(status: 501, code: "not_implemented", message: "\(path) is not implemented")
            return
        }
        sendHTTP(status: 404, code: "not_found", message: "not found")
    }

    private func sendHTTP(status: Int, code: String, message: String) {
        sendAndClose(buildHTTPResponse(status: status, reason: httpReason(status), body: httpErrorBody(code: code, message: message)))
    }

    private func sendAndClose(_ bytes: [UInt8]) {
        closing = true
        inactivity?.cancel()
        connection.send(content: Data(bytes), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.onClosed?()
        })
    }

    // MARK: WebSocket session

    private func setupAdapter() {
        let mode = live ? "live" : "mock"
        let profile = self.profile
        let queue = self.queue
        let factory = self.transportFactory
        let finishMode = self.finishMode
        let adapter = AdapterConnection(profile: profile, mode: mode, engineFactory: {
            try CoreEngine(profile: profile, transport: try factory(queue), queue: queue, finishMode: finishMode)
        }, emit: { [weak self] event in self?.sendText(event.compactJSONBytes()) })
        adapter.onTerminal = { [weak self] in self?.finishSession() }
        self.adapter = adapter
    }

    private func handleWSBytes(_ raw: UnsafeRawBufferPointer) {
        guard let parser = parser, let adapter = adapter else { return }
        let messages: [WSMessage]
        do { messages = try parser.feed(raw) } catch {
            adapter.handleFailure("websocket protocol error: \(error)", code: "invalid_request")
            return
        }
        for message in messages {
            if closing || adapter.terminalSent { return }
            switch message {
            case .text(let payload):
                handleText(payload, adapter: adapter)
            case .binary(let payload):
                do { try adapter.onPCM(payload) } catch let e as AdapterError { adapter.handleFailure(e) } catch { adapter.handleFailure("\(error)") }
            case .ping(let payload):
                connection.send(content: Data(wsEncodeFrame(payload, opcode: .pong, mask: false)), completion: .contentProcessed { _ in })
            case .pong:
                break
            case .close:
                // Client close: cancel the session immediately (spec §18.2).
                shutdown()
                return
            }
        }
    }

    private func handleText(_ payload: [UInt8], adapter: AdapterConnection) {
        if !startSeen {
            if payload.count > maxStartJSON {
                adapter.handleFailure("start JSON exceeds 1 MiB", code: "invalid_request"); return
            }
            let obj: JSONValue
            do { obj = try JSONParser.parse(payload) } catch {
                adapter.handleFailure("invalid start JSON: \(error)", code: "invalid_request"); return
            }
            startSeen = true
            do { try adapter.onStart(obj) } catch let e as AdapterError { adapter.handleFailure(e) } catch { adapter.handleFailure("\(error)") }
            if !adapter.terminalSent { armFinishTimer() }
            return
        }
        guard let obj = try? JSONParser.parse(payload) else { return } // Python: ignore non-JSON text frames
        if obj["type"] == .string("finish") {
            do { try adapter.onFinish() } catch let e as AdapterError { adapter.handleFailure(e) } catch { adapter.handleFailure("\(error)") }
            // The remote SessionFinished (→ final) is bounded by the finish timer.
            armFinishTimer()
        }
    }

    /// Bounds the wait for SessionStarted / SessionFinished (Python recv_timeout = 15 s).
    private func armFinishTimer() {
        finishTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + finalTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, let adapter = self.adapter, !adapter.terminalSent else { return }
            if !adapter.ready {
                adapter.handleFailure("timeout waiting for SessionStarted")
            } else if adapter.finishRequested {
                adapter.handleFailure("timeout waiting for SessionFinished")
            }
        }
        timer.resume()
        finishTimer = timer
    }

    private func sendText(_ payload: [UInt8]) {
        if closing { return }
        connection.send(content: Data(wsEncodeFrame(payload, opcode: .text, mask: false)), completion: .contentProcessed { _ in })
    }

    /// After final/error: close frame, then TCP close (mirrors `conn.close(); await ws.close()`).
    private func finishSession() {
        if closing { return }
        closing = true
        inactivity?.cancel()
        finishTimer?.cancel()
        adapter?.close()
        connection.send(content: Data(wsEncodeClose(mask: false)), isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            if error != nil { self?.shutdown() }
        })
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.shutdown() }
    }

    private func handleClientGone() {
        shutdown()
    }

    func shutdown() {
        if terminated { return }
        terminated = true
        closing = true
        inactivity?.cancel()
        finishTimer?.cancel()
        adapter?.close()
        connection.cancel()
        onClosed?()
    }
}
