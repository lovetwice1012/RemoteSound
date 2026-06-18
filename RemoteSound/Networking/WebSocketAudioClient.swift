import Foundation
import Network

final class WebSocketAudioClient {
    var onConnectionStateChange: ((String, Bool) -> Void)?
    var onSourceConnected: ((SourceDescriptor) -> Void)?
    var onSourceUpdated: ((SourceDescriptor) -> Void)?
    var onSourceDisconnected: ((UUID) -> Void)?
    var onAudioFrame: ((UUID, Data) -> Void)?

    private let queue = DispatchQueue(label: "RemoteSound.WebSocketClient")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var connection: NWConnection?
    private var pingTimer: DispatchSourceTimer?
    private var sourceID: UUID?
    private var sourceDescriptor: SourceDescriptor?
    private var desiredURL: URL?
    private var shouldStayConnected = false
    private var reconnectWorkItem: DispatchWorkItem?

    func connect(to url: URL) {
        queue.async {
            self.desiredURL = url
            self.shouldStayConnected = true
            self.startConnection(to: url)
        }
    }

    func reconnectIfNeeded() {
        queue.async {
            guard self.shouldStayConnected, self.connection == nil, let desiredURL = self.desiredURL else {
                return
            }

            self.startConnection(to: desiredURL)
        }
    }

    func disconnect() {
        queue.async {
            self.shouldStayConnected = false
            self.desiredURL = nil
            self.disconnectLocked(reason: "Disconnected.")
        }
    }

    func disconnectSource(id: UUID) {
        queue.async {
            guard self.sourceID == id else {
                return
            }

            self.shouldStayConnected = false
            self.desiredURL = nil
            self.disconnectLocked(reason: "Source disconnected.")
        }
    }

    func logDebugState(reason: String) {
        queue.async {
            NSLog(
                "WebSocketAudioClient.debug: reason=%@ connectionActive=%@ sourceID=%@ shouldStayConnected=%@",
                reason,
                self.connection == nil ? "false" : "true",
                self.sourceID?.uuidString ?? "nil",
                self.shouldStayConnected ? "true" : "false"
            )
        }
    }

    private func startConnection(to url: URL) {
        disconnectLocked(reason: nil)

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketOptions.maximumMessageSize = 65_536

        let tcpOptions = NWProtocolTCP.Options()
        let parameters: NWParameters
        if url.scheme == "wss" {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcpOptions)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        let connection = NWConnection(to: .url(url), using: parameters)
        let id = UUID()

        self.connection = connection
        self.sourceID = id
        self.sourceDescriptor = nil

        onConnectionStateChange?("Connecting to \(url.absoluteString) ...", false)
        NSLog("WebSocketAudioClient: connecting to %@", url.absoluteString)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else {
                return
            }

            self.queue.async {
                guard self.connection === connection else {
                    return
                }

                switch state {
                case .ready:
                    NSLog("WebSocketAudioClient: ready")
                    self.startPingTimer(for: connection)
                    self.receiveNext(from: connection, sourceID: id)
                case .failed(let error):
                    NSLog("WebSocketAudioClient: failed %@", error as NSError)
                    self.disconnectLocked(reason: "Connection lost: \(error.localizedDescription)")
                    self.scheduleReconnectIfNeeded()
                case .cancelled:
                    self.disconnectLocked(reason: "Connection closed.")
                    self.scheduleReconnectIfNeeded()
                default:
                    break
                }
            }
        }

        connection.start(queue: queue)
    }

    private func receiveNext(from connection: NWConnection, sourceID: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, contentContext, _, error in
            guard let self, let connection else {
                return
            }

            self.queue.async {
                guard self.connection === connection else {
                    return
                }

                if let error {
                    NSLog("WebSocketAudioClient.receive failed: %@", error as NSError)
                    self.disconnectLocked(reason: "Connection lost: \(error.localizedDescription)")
                    self.scheduleReconnectIfNeeded()
                    return
                }

                if let data,
                   let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    self.handle(data, opcode: metadata.opcode, from: connection, sourceID: sourceID)
                }

                if self.connection === connection {
                    self.receiveNext(from: connection, sourceID: sourceID)
                }
            }
        }
    }

    private func handle(_ data: Data, opcode: NWProtocolWebSocket.Opcode, from connection: NWConnection, sourceID: UUID) {
        switch opcode {
        case .text:
            handleTextMessage(data, from: connection, sourceID: sourceID)
        case .binary:
            guard sourceDescriptor != nil else {
                send(event: ServerEvent(type: "error", message: "Send hello before audio frames.", sourceID: sourceID.uuidString), to: connection)
                return
            }

            onAudioFrame?(sourceID, data)
        case .close:
            disconnectLocked(reason: "Connection closed.")
            scheduleReconnectIfNeeded()
        default:
            break
        }
    }

    private func handleTextMessage(_ data: Data, from connection: NWConnection, sourceID: UUID) {
        guard let hello = try? decoder.decode(ClientHello.self, from: data), hello.type == "hello" else {
            send(event: ServerEvent(type: "error", message: "Unsupported control message.", sourceID: sourceID.uuidString), to: connection)
            return
        }

        guard hello.channels == 2, hello.sampleRate == 48_000, hello.codec == "pcm_s16le" else {
            send(event: ServerEvent(type: "error", message: "RemoteSound currently expects 48 kHz stereo pcm_s16le.", sourceID: sourceID.uuidString), to: connection)
            disconnectLocked(reason: "Remote source format is not supported.")
            return
        }

        let descriptor = SourceDescriptor(
            id: sourceID,
            name: hello.name,
            stableID: hello.clientID?.nonEmpty ?? hello.name.lowercased(),
            endpointDescription: desiredURL?.absoluteString ?? "Remote WebSocket source",
            sampleRate: hello.sampleRate,
            channels: hello.channels,
            codec: hello.codec
        )

        let isFirstHello = sourceDescriptor == nil
        sourceDescriptor = descriptor

        if isFirstHello {
            onSourceConnected?(descriptor)
        }
        onSourceUpdated?(descriptor)
        onConnectionStateChange?("Connected to \(descriptor.name).", true)

        send(
            event: ServerEvent(
                type: "accepted",
                message: "RemoteSound is receiving \(hello.frameSamples) stereo frames per packet.",
                sourceID: sourceID.uuidString
            ),
            to: connection
        )
    }

    private func send(event: ServerEvent, to connection: NWConnection) {
        guard let payload = try? encoder.encode(event) else {
            return
        }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func startPingTimer(for connection: NWConnection) {
        pingTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else {
                return
            }

            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            let context = NWConnection.ContentContext(identifier: UUID().uuidString, metadata: [metadata])
            connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
        }
        timer.resume()
        pingTimer = timer
    }

    private func scheduleReconnectIfNeeded() {
        guard shouldStayConnected, let desiredURL else {
            return
        }

        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.startConnection(to: desiredURL)
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func disconnectLocked(reason: String?) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        pingTimer?.cancel()
        pingTimer = nil

        let disconnectedSourceID = sourceID
        connection?.cancel()
        connection = nil
        sourceID = nil
        sourceDescriptor = nil

        if let disconnectedSourceID {
            onSourceDisconnected?(disconnectedSourceID)
        }

        if let reason {
            onConnectionStateChange?(reason, false)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
