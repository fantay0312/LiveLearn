// Live Frontier WSS transport on Network.framework (TLS + NWProtocolWebSocket).
//
// Full duplex by construction: `send` hands the frame to the kernel-facing stack and returns;
// an always-armed receiveMessage loop delivers every server frame on the engine queue the
// instant it arrives. TCP_NODELAY on, service class .responsiveData (interactive request/response
// traffic: lower queueing than best-effort, without the strict pacing assumptions of
// .interactiveVoice which is meant for constant-bitrate media).
import Foundation
import Network
import TypelessCore

public struct LiveTransportError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class LiveTransport: ASRTransport {
    public let profile: ASRProfile
    public let queue: DispatchQueue
    public let timeout: TimeInterval
    public var onMessage: (([UInt8]) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public private(set) var bytesSent = 0
    public private(set) var bytesReceived = 0
    public private(set) var connectLatencyMs: Double = 0

    private var connection: NWConnection?
    private var opened = false
    private var closed = false
    private var openCompletion: ((Error?) -> Void)?
    private var connectTimer: DispatchWorkItem?

    public init(profile: ASRProfile, queue: DispatchQueue, timeout: TimeInterval = 15) {
        self.profile = profile
        self.queue = queue
        self.timeout = timeout
    }

    public static func makeParameters(urlString: String, headers: [(String, String)]) throws -> NWParameters {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "wss" || scheme == "ws" else {
            throw LiveTransportError("unsupported url \(urlString)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        let params: NWParameters
        if scheme == "wss" {
            let tls = NWProtocolTLS.Options() // default: verify chain + hostname (SNI from URL)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.serviceClass = .responsiveData
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024
        ws.setAdditionalHeaders(headers)
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    public func open(completion: @escaping (Error?) -> Void) {
        if opened { completion(LiveTransportError("transport already opened")); return }
        opened = true
        let urlString = profile.websocketURL()
        guard let url = URL(string: urlString) else { completion(LiveTransportError("bad url")); return }
        let params: NWParameters
        do { params = try LiveTransport.makeParameters(urlString: urlString, headers: profile.headers()) } catch {
            completion(error); return
        }
        let conn = NWConnection(to: .url(url), using: params)
        connection = conn
        openCompletion = completion
        let t0 = monotonicNanos()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.connectLatencyMs = Double(monotonicNanos() - t0) / 1e6
                self.connectTimer?.cancel()
                self.receiveLoop()
                let cb = self.openCompletion
                self.openCompletion = nil
                cb?(nil)
            case .failed(let err):
                self.finishWithError(LiveTransportError("connection failed: \(err)"))
            case .waiting(let err):
                // No path yet (offline / DNS); the connect timer bounds the wait.
                _ = err
            case .cancelled:
                if !self.closed { self.finishWithError(LiveTransportError("connection cancelled")) }
            default:
                break
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.openCompletion != nil else { return }
            self.finishWithError(LiveTransportError("connect timeout after \(Int(self.timeout))s"))
        }
        connectTimer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        conn.start(queue: queue)
    }

    private func finishWithError(_ error: Error) {
        connectTimer?.cancel()
        if let cb = openCompletion {
            openCompletion = nil
            cb(error)
            return
        }
        if closed { return }
        closed = true
        onFailure?(error)
    }

    private func receiveLoop() {
        guard let conn = connection, !closed else { return }
        conn.receiveMessage { [weak self] content, context, _, error in
            guard let self = self else { return }
            if let error = error {
                self.finishWithError(LiveTransportError("receive failed: \(error)"))
                return
            }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .close:
                    if !self.closed {
                        self.closed = true
                        self.onFailure?(LiveTransportError("remote closed websocket (code \(meta.closeCode))"))
                    }
                    return
                case .ping, .pong:
                    break // autoReplyPing answers pings; nothing to surface
                default:
                    if let data = content {
                        self.bytesReceived += data.count
                        self.onMessage?([UInt8](data))
                    }
                }
            } else if let data = content, !data.isEmpty {
                self.bytesReceived += data.count
                self.onMessage?([UInt8](data))
            }
            if context?.isFinal == true && content == nil {
                if !self.closed {
                    self.closed = true
                    self.onFailure?(LiveTransportError("connection ended"))
                }
                return
            }
            self.receiveLoop()
        }
    }

    public func send(_ data: [UInt8]) throws {
        guard let conn = connection, !closed else { throw LiveTransportError("transport not open") }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "bin", metadata: [metadata])
        bytesSent += data.count
        conn.send(content: Data(data), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let error = error, let self = self, !self.closed {
                self.closed = true
                self.onFailure?(LiveTransportError("send failed: \(error)"))
            }
        })
    }

    public func close() {
        guard let conn = connection else { return }
        if closed { conn.cancel(); connection = nil; return }
        closed = true
        connectTimer?.cancel()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        conn.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        connection = nil
    }
}
