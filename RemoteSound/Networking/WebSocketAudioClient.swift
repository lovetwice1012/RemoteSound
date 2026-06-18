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
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
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
            guard self.shouldStayConnected, self.task == nil, let desiredURL = self.desiredURL else {
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
                "WebSocketAudioClient.debug: reason=%@ taskActive=%@ sourceID=%@ shouldStayConnected=%@",
                reason,
                self.task == nil ? "false" : "true",
                self.sourceID?.uuidString ?? "nil",
                self.shouldStayConnected ? "true" : "false"
            )
        }
    }

    private func startConnection(to url: URL) {
        disconnectLocked(reason: nil)

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 0

        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: url)
        let id = UUID()

        self.session = session
        self.task = task
        self.sourceID = id
        self.sourceDescriptor = nil

        onConnectionStateChange?("Connecting to \(url.absoluteString) ...", false)
        NSLog("WebSocketAudioClient: connecting to %@", url.absoluteString)

        task.resume()
        startPingTimer(for: task)
        receiveNext(from: task, sourceID: id)
    }

    private func receiveNext(from task: URLSessionWebSocketTask, sourceID: UUID) {
        task.receive { [weak self] result in
            guard let self else {
                return
            }

            self.queue.async {
                guard self.task === task else {
                    return
                }

                switch result {
                case .success(let message):
                    self.handle(message, from: task, sourceID: sourceID)
                    if self.task === task {
                        self.receiveNext(from: task, sourceID: sourceID)
                    }
                case .failure(let error):
                    let nsError = error as NSError
                    NSLog("WebSocketAudioClient.receive failed: %@", nsError)
                    self.disconnectLocked(reason: "Connection lost: \(error.localizedDescription)")
                    self.scheduleReconnectIfNeeded()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from task: URLSessionWebSocketTask, sourceID: UUID) {
        switch message {
        case .string(let text):
            handleTextMessage(Data(text.utf8), from: task, sourceID: sourceID)
        case .data(let data):
            guard sourceDescriptor != nil else {
                send(event: ServerEvent(type: "error", message: "Send hello before audio frames.", sourceID: sourceID.uuidString), to: task)
                return
            }

            onAudioFrame?(sourceID, data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ data: Data, from task: URLSessionWebSocketTask, sourceID: UUID) {
        guard let hello = try? decoder.decode(ClientHello.self, from: data), hello.type == "hello" else {
            send(event: ServerEvent(type: "error", message: "Unsupported control message.", sourceID: sourceID.uuidString), to: task)
            return
        }

        guard hello.channels == 2, hello.sampleRate == 48_000, hello.codec == "pcm_s16le" else {
            send(event: ServerEvent(type: "error", message: "RemoteSound currently expects 48 kHz stereo pcm_s16le.", sourceID: sourceID.uuidString), to: task)
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
            to: task
        )
    }

    private func send(event: ServerEvent, to task: URLSessionWebSocketTask) {
        guard let payload = try? encoder.encode(event),
              let text = String(data: payload, encoding: .utf8) else {
            return
        }

        task.send(.string(text)) { error in
            if let error {
                NSLog("WebSocketAudioClient.send failed: %@", error as NSError)
            }
        }
    }

    private func startPingTimer(for task: URLSessionWebSocketTask) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task, self.task === task else {
                return
            }

            task.sendPing { error in
                if let error {
                    NSLog("WebSocketAudioClient.ping failed: %@", error as NSError)
                }
            }
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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
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
