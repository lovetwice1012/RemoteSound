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

        try startListener()
    }

    func restartIfNeeded() {
        queue.async {
            guard self.listener == nil else {
                NSLog("WebSocketAudioServer.restartIfNeeded: listener already active")
                return
            }

            do {
                NSLog("WebSocketAudioServer.restartIfNeeded: restarting listener")
                try self.startListener()
            } catch {
                let nsError = error as NSError
                self.onServerStateChange?("Server restart failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))")
                NSLog("Server restart error: %@", nsError)
            }
        }
    }

    func logDebugState(reason: String) {
        queue.async {
            let completedHandshakeCount = self.connections.values.filter { $0.hasCompletedHandshake }.count
            NSLog(
                "WebSocketAudioServer.debug: reason=%@ listenerActive=%@ connections=%d completedHandshakes=%d",
                reason,
                self.listener == nil ? "false" : "true",
                self.connections.count,
                completedHandshakeCount
            )
        }
    }

    private func startListener() throws {
        NSLog("WebSocketAudioServer.startListener: creating listener on port %d", Int(port))
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
                NSLog("WebSocketAudioServer.listener: ready on port %d", Int(port.rawValue))
                self?.onServerStateChange?("Listening on port \(port.rawValue)")
            case .failed(let error):
                let nsError = error as NSError
                self?.onServerStateChange?("Listener failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))")
                NSLog("NWListener failed: %@", nsError)
                self?.markListenerStopped(listener)
            case .cancelled:
                self?.onServerStateChange?("Listener stopped")
                self?.markListenerStopped(listener)
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
        NSLog("WebSocketAudioServer.accept: id=%@", id.uuidString)
        let descriptor = SourceDescriptor(
            id: id,
            name: "Pending source",
            stableID: id.uuidString,
            endpointDescription: Self.endpointDescription(for: connection.endpoint),
            sampleRate: 48_000,
            channels: 2,
            codec: "pcm_s16le"
        )

        let context = ConnectionContext(id: id, connection: connection, descriptor: descriptor)
        connections[id] = context

        onSourceConnected?(descriptor)

        connection.stateUpdateHandler = { [weak self] state in
            NSLog(
                "WebSocketAudioServer.connection: id=%@ state=%@",
                id.uuidString,
                String(describing: state)
            )
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
                    guard context.hasCompletedHandshake else {
                        self.send(event: ServerEvent(type: "error", message: "Send hello before audio frames.", sourceID: context.id.uuidString), to: context)
                        break
                    }

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

        guard hello.channels == 2, hello.sampleRate == 48_000, hello.codec == "pcm_s16le" else {
            send(event: ServerEvent(type: "error", message: "RemoteSound currently expects 48 kHz stereo pcm_s16le.", sourceID: context.id.uuidString), to: context)
            context.connection.cancel()
            removeConnection(id: context.id)
            return
        }

        let bytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = hello.channels * bytesPerSample
        guard hello.frameSamples > 0, hello.frameSamples <= 4_096, bytesPerFrame > 0 else {
            send(event: ServerEvent(type: "error", message: "Invalid audio frame settings.", sourceID: context.id.uuidString), to: context)
            context.connection.cancel()
            removeConnection(id: context.id)
            return
        }

        context.descriptor.name = hello.name
        context.descriptor.stableID = hello.clientID?.nonEmpty ?? Self.makeFallbackStableID(name: hello.name, endpoint: context.descriptor.endpointDescription)
        context.descriptor.sampleRate = hello.sampleRate
        context.descriptor.channels = hello.channels
        context.descriptor.codec = hello.codec
        context.hasCompletedHandshake = true
        context.lastActivityAt = Date()
        onSourceUpdated?(context.descriptor)

        send(
            event: ServerEvent(
                type: "accepted",
                message: "Streaming \(hello.frameSamples) stereo frames per packet.",
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

    private func markListenerStopped(_ stoppedListener: NWListener) {
        if listener === stoppedListener {
            listener = nil
        }
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
            guard !context.hasCompletedHandshake,
                  now.timeIntervalSince(context.lastActivityAt) >= handshakeTimeout else {
                return nil
            }

            return id
        }

        guard !staleIDs.isEmpty else {
            return
        }

        onServerStateChange?("Removed \(staleIDs.count) pending source connection(s).")
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
