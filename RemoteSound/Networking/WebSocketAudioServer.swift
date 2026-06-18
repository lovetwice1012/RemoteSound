import Foundation
import Network

final class WebSocketAudioServer {
    private final class ConnectionContext {
        let id: UUID
        let connection: NWConnection
        var descriptor: SourceDescriptor
        var lastActivityAt = Date()
        var hasCompletedHandshake = false

        init(id: UUID, connection: NWConnection, descriptor: SourceDescriptor) {
            self.id = id
            self.connection = connection
            self.descriptor = descriptor
        }
    }

    let port: UInt16
    var onServerStateChange: ((String) -> Void)?
    var onSourceConnected: ((SourceDescriptor) -> Void)?
    var onSourceUpdated: ((SourceDescriptor) -> Void)?
    var onSourceDisconnected: ((UUID) -> Void)?
    var onAudioFrame: ((UUID, Data) -> Void)?

    private let queue = DispatchQueue(label: "RemoteSound.WebSocketServer")
    private let handshakeTimeout: TimeInterval = 5
    private let audioInactivityTimeout: TimeInterval = 15
    private var listener: NWListener?
    private var cleanupTimer: DispatchSourceTimer?
    private var connections: [UUID: ConnectionContext] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        if listener != nil {
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = 65_536
        webSocketOptions.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }

        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        let port = NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: port)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onServerStateChange?("Listening on port \(port.rawValue)")
            case .failed(let error):
                let nsError = error as NSError
                self?.onServerStateChange?("Listener failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))")
                NSLog("NWListener failed: %@", nsError)
            case .cancelled:
                self?.onServerStateChange?("Listener stopped")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }

        listener.start(queue: queue)
        self.listener = listener
        startCleanupTimerIfNeeded()
    }

    func stop() {
        queue.async {
            self.connections.values.forEach { $0.connection.cancel() }
            self.connections.removeAll()
            self.cleanupTimer?.cancel()
            self.cleanupTimer = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    func disconnectSource(id: UUID) {
        queue.async {
            self.removeConnection(id: id)
        }
    }

    private func accept(connection: NWConnection) {
        let id = UUID()
        let descriptor = SourceDescriptor(
            id: id,
            name: "Pending source",
            stableID: id.uuidString,
            endpointDescription: Self.endpointDescription(for: connection.endpoint),
            sampleRate: 48_000,
            codec: "pcm_s16le"
        )

        let context = ConnectionContext(id: id, connection: connection, descriptor: descriptor)
        connections[id] = context

        onSourceConnected?(descriptor)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.onServerStateChange?("Connection failed: \(error.localizedDescription)")
                self?.removeConnection(id: id)
            case .cancelled:
                self?.removeConnection(id: id)
            default:
                break
            }
        }

        connection.start(queue: queue)
        send(event: ServerEvent(type: "ready", message: "Connected to RemoteSound", sourceID: id.uuidString), to: context)
        receiveNext(from: context)
    }

    private func receiveNext(from context: ConnectionContext) {
        context.connection.receiveMessage { [weak self] data, contentContext, _, error in
            guard let self else {
                return
            }

            if let error {
                if case .posix(let code) = error, code == .EINVAL {
                    self.receiveNext(from: context)
                    return
                }

                self.removeConnection(id: context.id)
                return
            }

            if let data,
               let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                context.lastActivityAt = Date()

                switch metadata.opcode {
                case .text:
                    self.handleTextMessage(data, for: context)
                case .binary:
                    self.onAudioFrame?(context.id, data)
                case .close:
                    self.removeConnection(id: context.id)
                    return
                default:
                    break
                }
            }

            self.receiveNext(from: context)
        }
    }

    private func handleTextMessage(_ data: Data, for context: ConnectionContext) {
        guard let hello = try? decoder.decode(ClientHello.self, from: data) else {
            send(event: ServerEvent(type: "error", message: "Unsupported control message.", sourceID: context.id.uuidString), to: context)
            return
        }

        guard hello.type == "hello" else {
            send(event: ServerEvent(type: "error", message: "Unsupported control message.", sourceID: context.id.uuidString), to: context)
            return
        }

        guard hello.channels == 1, hello.sampleRate == 48_000, hello.codec == "pcm_s16le" else {
            send(event: ServerEvent(type: "error", message: "RemoteSound currently expects 48 kHz mono pcm_s16le.", sourceID: context.id.uuidString), to: context)
            context.connection.cancel()
            removeConnection(id: context.id)
            return
        }

        context.descriptor.name = hello.name
        context.descriptor.stableID = hello.clientID?.nonEmpty ?? Self.makeFallbackStableID(name: hello.name, endpoint: context.descriptor.endpointDescription)
        context.descriptor.sampleRate = hello.sampleRate
        context.descriptor.codec = hello.codec
        context.hasCompletedHandshake = true
        context.lastActivityAt = Date()
        onSourceUpdated?(context.descriptor)

        send(
            event: ServerEvent(
                type: "accepted",
                message: "Streaming \(hello.frameSamples) samples per frame.",
                sourceID: context.id.uuidString
            ),
            to: context
        )
    }

    private func send(event: ServerEvent, to context: ConnectionContext) {
        guard let payload = try? encoder.encode(event) else {
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let contentContext = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
        context.connection.send(content: payload, contentContext: contentContext, isComplete: true, completion: .idempotent)
    }

    private func removeConnection(id: UUID) {
        guard let context = connections.removeValue(forKey: id) else {
            return
        }

        context.connection.cancel()
        onSourceDisconnected?(id)
    }

    private func startCleanupTimerIfNeeded() {
        guard cleanupTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.pruneInactiveConnections()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func pruneInactiveConnections() {
        let now = Date()
        let staleIDs = connections.compactMap { id, context -> UUID? in
            let timeout = context.hasCompletedHandshake ? audioInactivityTimeout : handshakeTimeout
            guard now.timeIntervalSince(context.lastActivityAt) >= timeout else {
                return nil
            }

            return id
        }

        guard !staleIDs.isEmpty else {
            return
        }

        onServerStateChange?("Removed \(staleIDs.count) inactive source connection(s).")
        staleIDs.forEach { staleID in
            removeConnection(id: staleID)
        }
    }

    private static func endpointDescription(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port.rawValue)"
        default:
            return endpoint.debugDescription
        }
    }

    private static func makeFallbackStableID(name: String, endpoint: String) -> String {
        "\(name.lowercased())|\(endpoint.lowercased())"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
