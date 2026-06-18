import AVFAudio
import Foundation

final class AudioMixerController {
    private struct ChannelSettings {
        var isEnabled = true
        var volume: Float = 1.0
        var lowGain: Float = 0.0
        var midGain: Float = 0.0
        var highGain: Float = 0.0
    }

    private final class SourceChannel {
        let playerNode = AVAudioPlayerNode()
        let equalizer = AVAudioUnitEQ(numberOfBands: 3)
        let volumeNode = AVAudioMixerNode()
        let format: AVAudioFormat
        var pendingBuffers: [AVAudioPCMBuffer] = []
        var scheduledBufferCount = 0
        var hasStartedPlayback = false
        var droppedFrameCount = 0
        var settings = ChannelSettings()

        init(format: AVAudioFormat) {
            self.format = format
            configureBands()
        }

        func configureBands() {
            let bands = equalizer.bands

            bands[0].filterType = .lowShelf
            bands[0].frequency = 120
            bands[0].bypass = false
            bands[0].bandwidth = 1

            bands[1].filterType = .parametric
            bands[1].frequency = 1_000
            bands[1].bypass = false
            bands[1].bandwidth = 1

            bands[2].filterType = .highShelf
            bands[2].frequency = 8_000
            bands[2].bypass = false
            bands[2].bandwidth = 1
        }

        func applySettings() {
            volumeNode.outputVolume = settings.isEnabled ? settings.volume : 0
            equalizer.bands[0].gain = settings.lowGain
            equalizer.bands[1].gain = settings.midGain
            equalizer.bands[2].gain = settings.highGain
        }
    }

    private let engine = AVAudioEngine()
    private let engineQueue = DispatchQueue(label: "RemoteSound.AudioMixer")
    private let sampleRate: Double
    private let channelCount: AVAudioChannelCount
    private let minimumLeadBufferCount = 3
    private let targetLeadBufferCount = 6
    private let maximumQueuedBufferCount = 18
    private var notificationTokens: [NSObjectProtocol] = []
    private var channels: [UUID: SourceChannel] = [:]
    var onSourceStatsChanged: ((UUID, AudioSourceRuntimeStats) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    init(sampleRate: Double = 48_000, channelCount: AVAudioChannelCount = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        installNotificationObservers()
    }

    deinit {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
    }

    func start() throws {
        try configureSession()

        var caughtError: Error?
        engineQueue.sync {
            guard !engine.isRunning else {
                return
            }

            engine.prepare()

            do {
                try engine.start()
            } catch {
                caughtError = error
            }
        }

        if let caughtError {
            throw caughtError
        }
    }

    func reactivateIfNeeded(reason: String) {
        reactivateSession(reason: reason)
    }

    func registerSource(id: UUID) {
        engineQueue.async {
            guard self.channels[id] == nil else {
                return
            }

            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: self.sampleRate,
                channels: self.channelCount,
                interleaved: false
            )

            guard let format else {
                return
            }

            let channel = SourceChannel(format: format)

            self.engine.attach(channel.playerNode)
            self.engine.attach(channel.equalizer)
            self.engine.attach(channel.volumeNode)

            self.engine.connect(channel.playerNode, to: channel.equalizer, format: format)
            self.engine.connect(channel.equalizer, to: channel.volumeNode, format: format)
            self.engine.connect(channel.volumeNode, to: self.engine.mainMixerNode, format: format)

            channel.applySettings()
            self.channels[id] = channel
            self.reportStats(for: id, channel: channel)
        }
    }

    func unregisterSource(id: UUID) {
        engineQueue.async {
            guard let channel = self.channels.removeValue(forKey: id) else {
                return
            }

            channel.pendingBuffers.removeAll()
            channel.playerNode.stop()
            self.engine.disconnectNodeInput(channel.equalizer)
            self.engine.disconnectNodeOutput(channel.playerNode)
            self.engine.disconnectNodeOutput(channel.equalizer)
            self.engine.disconnectNodeOutput(channel.volumeNode)
            self.engine.detach(channel.playerNode)
            self.engine.detach(channel.equalizer)
            self.engine.detach(channel.volumeNode)
        }
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        engineQueue.async {
            guard let channel = self.channels[id] else {
                return
            }

            channel.settings.isEnabled = isEnabled
            channel.applySettings()
            self.reportStats(for: id, channel: channel)
        }
    }

    func setVolume(_ volume: Double, for id: UUID) {
        engineQueue.async {
            guard let channel = self.channels[id] else {
                return
            }

            channel.settings.volume = Float(volume)
            channel.applySettings()
        }
    }

    func setEqualizer(low: Double, mid: Double, high: Double, for id: UUID) {
        engineQueue.async {
            guard let channel = self.channels[id] else {
                return
            }

            channel.settings.lowGain = Float(low)
            channel.settings.midGain = Float(mid)
            channel.settings.highGain = Float(high)
            channel.applySettings()
        }
    }

    func enqueuePCM16Frame(_ payload: Data, for id: UUID) {
        engineQueue.async {
            guard let channel = self.channels[id] else {
                return
            }

            guard let buffer = Self.makeBuffer(from: payload, format: channel.format) else {
                return
            }

            if channel.pendingBuffers.count >= self.maximumQueuedBufferCount {
                channel.pendingBuffers.removeFirst()
                channel.droppedFrameCount += 1
            }

            channel.pendingBuffers.append(buffer)
            self.pumpBuffers(for: id, channel: channel)
            self.reportStats(for: id, channel: channel)
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .allowAirPlay])
        try session.setActive(true)
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        let interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        let routeChangeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }

        notificationTokens.append(interruptionToken)
        notificationTokens.append(routeChangeToken)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch interruptionType {
        case .began:
            onStatusMessage?("Audio session interrupted.")
        case .ended:
            onStatusMessage?("Audio interruption ended. Reactivating playback.")
            reactivateSession(reason: "interruption ended")
        @unknown default:
            onStatusMessage?("Audio session interruption changed.")
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            onStatusMessage?("Audio route changed: new output available.")
        case .oldDeviceUnavailable:
            onStatusMessage?("Audio route changed: previous output disconnected.")
            reactivateSession(reason: "route disconnected")
        case .routeConfigurationChange:
            onStatusMessage?("Audio route configuration changed.")
            reactivateSession(reason: "route configuration changed")
        default:
            break
        }
    }

    private func reactivateSession(reason: String) {
        engineQueue.async {
            do {
                try self.configureSession()

                if !self.engine.isRunning {
                    self.engine.prepare()
                    try self.engine.start()
                }

                for (id, channel) in self.channels {
                    let totalBufferedCount = channel.scheduledBufferCount + channel.pendingBuffers.count

                    if totalBufferedCount >= self.minimumLeadBufferCount || channel.hasStartedPlayback {
                        if !channel.playerNode.isPlaying {
                            channel.playerNode.play()
                        }

                        if totalBufferedCount > 0 {
                            channel.hasStartedPlayback = true
                        }
                    }

                    self.pumpBuffers(for: id, channel: channel)
                    self.reportStats(for: id, channel: channel)
                }

                self.onStatusMessage?("Audio session active after \(reason).")
            } catch {
                self.onStatusMessage?("Audio session recovery failed: \(error.localizedDescription)")
            }
        }
    }

    private func pumpBuffers(for id: UUID, channel: SourceChannel) {
        let totalBufferedCount = channel.scheduledBufferCount + channel.pendingBuffers.count

        if !channel.hasStartedPlayback, totalBufferedCount >= minimumLeadBufferCount {
            channel.playerNode.play()
            channel.hasStartedPlayback = true
        }

        while channel.scheduledBufferCount < targetLeadBufferCount, !channel.pendingBuffers.isEmpty {
            let buffer = channel.pendingBuffers.removeFirst()
            channel.scheduledBufferCount += 1

            channel.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else {
                    return
                }

                self.engineQueue.async {
                    guard let activeChannel = self.channels[id] else {
                        return
                    }

                    activeChannel.scheduledBufferCount = max(0, activeChannel.scheduledBufferCount - 1)

                    if activeChannel.scheduledBufferCount == 0, activeChannel.pendingBuffers.isEmpty {
                        activeChannel.hasStartedPlayback = false
                        activeChannel.playerNode.stop()
                    } else {
                        self.pumpBuffers(for: id, channel: activeChannel)
                    }

                    self.reportStats(for: id, channel: activeChannel)
                }
            }
        }
    }

    private func reportStats(for id: UUID, channel: SourceChannel) {
        let stats = AudioSourceRuntimeStats(
            queuedBufferCount: channel.pendingBuffers.count + channel.scheduledBufferCount,
            droppedFrameCount: channel.droppedFrameCount,
            isActivelyPlaying: channel.hasStartedPlayback
        )
        onSourceStatsChanged?(id, stats)
    }

    private static func makeBuffer(from payload: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let channelCount = Int(format.channelCount)
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard channelCount > 0, sampleCount >= channelCount else {
            return nil
        }

        let frameCount = sampleCount / channelCount
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        payload.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard let floatChannels = buffer.floatChannelData else {
                return
            }

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sampleIndex = (frame * channelCount) + channel
                    let normalized = Float(samples[sampleIndex]) / Float(Int16.max)
                    floatChannels[channel][frame] = normalized
                }
            }
        }

        return buffer
    }
}
