import AVFAudio
import Foundation

enum AudioMixerError: LocalizedError {
    case invalidOutputFormat(sampleRate: Double, channelCount: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case let .invalidOutputFormat(sampleRate, channelCount):
            return "Invalid audio output format: sampleRate=\(sampleRate), channelCount=\(channelCount)."
        }
    }
}

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
    private let backgroundKeepAliveChannelCount: AVAudioChannelCount = 2
    private let backgroundKeepAliveDuration: Double = 0.25
    private let minimumLeadBufferCount = 3
    private let targetLeadBufferCount = 6
    private let maximumQueuedBufferCount = 18
    private var notificationTokens: [NSObjectProtocol] = []
    private var channels: [UUID: SourceChannel] = [:]
    private let backgroundKeepAliveNode = AVAudioPlayerNode()
    private var backgroundKeepAliveFormat: AVAudioFormat?
    private var backgroundKeepAliveBuffer: AVAudioPCMBuffer?
    private var backgroundKeepAliveIsAttached = false
    private var backgroundKeepAliveIsScheduled = false
    var onSourceStatsChanged: ((UUID, AudioSourceRuntimeStats) -> Void)?
    var onStatusMessage: ((String) -> Void)?

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        installNotificationObservers()
    }

    deinit {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
    }

    func start() throws {
        NSLog("AudioMixerController.start: beginning configureSession")
        do {
            try configureSession()
            let session = AVAudioSession.sharedInstance()
            NSLog("AudioMixerController.start: configureSession succeeded (sampleRate=%f ioBufferDuration=%f)", session.sampleRate, session.ioBufferDuration)
        } catch {
            NSLog("AudioMixerController.start: configureSession failed: %@", error as NSError)
            throw error
        }

        // Do not call AVAudioEngine.prepare() or start the engine here.
        // On iOS, prepare() can raise an Objective-C exception when the graph is not
        // fully initialized yet; Swift do-catch cannot catch that exception.
        // The engine is started lazily after the first source node has been attached
        // and connected.
        NSLog("AudioMixerController.start: session is active; engine will start after the first source is connected")
    }

    func reactivateIfNeeded(reason: String) {
        reactivateSession(reason: reason)
    }

    func prepareForBackgroundPlayback() {
        engineQueue.async {
            do {
                try self.configureSession()
                if !self.channels.isEmpty {
                    try self.ensureEngineRunningLocked(reason: "app entering background")
                    self.ensureBackgroundKeepAliveRunningLocked()
                    self.onStatusMessage?("Background audio active.")
                }
            } catch {
                NSLog("AudioMixerController.prepareForBackgroundPlayback failed: %@", error as NSError)
                self.onStatusMessage?("Background audio setup failed: \(error.localizedDescription)")
            }
        }
    }

    func registerSource(id: UUID, sampleRate: Double, channelCount: AVAudioChannelCount) {
        engineQueue.async {
            if let existingChannel = self.channels[id] {
                if existingChannel.format.sampleRate == sampleRate, existingChannel.format.channelCount == channelCount {
                    return
                }

                self.removeSourceChannel(id: id, channel: existingChannel)
            }

            guard sampleRate > 0, channelCount > 0 else {
                NSLog("AudioMixerController.registerSource: invalid format sampleRate=%f channelCount=%u", sampleRate, channelCount)
                return
            }

            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            )

            guard let format else {
                NSLog("AudioMixerController.registerSource: failed to create AVAudioFormat sampleRate=%f channelCount=%u", sampleRate, channelCount)
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

            do {
                try self.ensureEngineRunningLocked(reason: "source registered")
                self.onStatusMessage?("Audio engine active.")
            } catch {
                NSLog("AudioMixerController.registerSource: engine start failed: %@", error as NSError)
                self.onStatusMessage?("Audio engine start failed: \(error.localizedDescription)")
                self.removeSourceChannel(id: id, channel: channel)
                return
            }

            self.reportStats(for: id, channel: channel)
        }
    }

    func unregisterSource(id: UUID) {
        engineQueue.async {
            guard let channel = self.channels[id] else {
                return
            }

            self.removeSourceChannel(id: id, channel: channel)
            self.stopEngineIfIdleLocked()
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

    private func ensureEngineRunningLocked(reason: String) throws {
        guard !engine.isRunning else {
            ensureBackgroundKeepAliveRunningLocked()
            return
        }

        guard !channels.isEmpty else {
            NSLog("AudioMixerController.ensureEngineRunningLocked: skipped because there are no source channels (reason=%@)", reason)
            return
        }

        try configureBackgroundKeepAliveLocked()

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            NSLog(
                "AudioMixerController.ensureEngineRunningLocked: invalid output format sampleRate=%f channelCount=%u",
                outputFormat.sampleRate,
                outputFormat.channelCount
            )
            throw AudioMixerError.invalidOutputFormat(
                sampleRate: outputFormat.sampleRate,
                channelCount: outputFormat.channelCount
            )
        }

        NSLog(
            "AudioMixerController.ensureEngineRunningLocked: starting engine (reason=%@ outputSampleRate=%f outputChannels=%u sources=%d)",
            reason,
            outputFormat.sampleRate,
            outputFormat.channelCount,
            channels.count
        )

        // prepare() is intentionally omitted. AVAudioEngine.start() performs the
        // required initialization and reports recoverable failures as thrown errors.
        try engine.start()
        ensureBackgroundKeepAliveRunningLocked()
    }

    private func configureBackgroundKeepAliveLocked() throws {
        if backgroundKeepAliveIsAttached {
            return
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: backgroundKeepAliveChannelCount
        ) else {
            throw AudioMixerError.invalidOutputFormat(
                sampleRate: sampleRate,
                channelCount: backgroundKeepAliveChannelCount
            )
        }

        let frameCapacity = max(
            AVAudioFrameCount(1),
            AVAudioFrameCount(sampleRate * backgroundKeepAliveDuration)
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw AudioMixerError.invalidOutputFormat(
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            )
        }

        buffer.frameLength = frameCapacity
        if let floatChannels = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frameCapacity) {
                    floatChannels[channel][frame] = 0
                }
            }
        }

        engine.attach(backgroundKeepAliveNode)
        engine.connect(backgroundKeepAliveNode, to: engine.mainMixerNode, format: format)
        backgroundKeepAliveFormat = format
        backgroundKeepAliveBuffer = buffer
        backgroundKeepAliveIsAttached = true

        NSLog(
            "AudioMixerController: background keep-alive node attached (sampleRate=%f channels=%u frames=%u)",
            format.sampleRate,
            format.channelCount,
            frameCapacity
        )
    }

    private func ensureBackgroundKeepAliveRunningLocked() {
        guard backgroundKeepAliveIsAttached, let buffer = backgroundKeepAliveBuffer else {
            return
        }

        if !backgroundKeepAliveIsScheduled {
            backgroundKeepAliveNode.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            backgroundKeepAliveIsScheduled = true
        }

        if !backgroundKeepAliveNode.isPlaying {
            backgroundKeepAliveNode.play()
        }
    }

    private func stopBackgroundKeepAliveLocked() {
        guard backgroundKeepAliveIsAttached else {
            return
        }

        backgroundKeepAliveNode.stop()
        backgroundKeepAliveIsScheduled = false
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try audioStep("setCategory") {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }

        // Try to request the preferred sample rate and IO buffer duration, but don't fail if unavailable.
        do {
            try session.setPreferredSampleRate(sampleRate)
        } catch {
            NSLog("setPreferredSampleRate failed: %@", error as NSError)
        }

        do {
            try session.setPreferredIOBufferDuration(0.02)
        } catch {
            NSLog("setPreferredIOBufferDuration failed: %@", error as NSError)
        }

        try audioStep("setActive") {
            try session.setActive(true)
        }
    }

    private func audioStep(_ name: String, _ body: () throws -> Void) throws {
        do {
            try body()
            NSLog("AudioMixerController.configureSession OK: %@", name)
        } catch {
            NSLog("AudioMixerController.configureSession FAILED: %@ %@", name, error as NSError)
            throw error
        }
    }

    private func removeSourceChannel(id: UUID, channel: SourceChannel) {
        channels.removeValue(forKey: id)
        channel.pendingBuffers.removeAll()
        channel.playerNode.stop()
        engine.disconnectNodeInput(channel.equalizer)
        engine.disconnectNodeOutput(channel.playerNode)
        engine.disconnectNodeOutput(channel.equalizer)
        engine.disconnectNodeOutput(channel.volumeNode)
        engine.detach(channel.playerNode)
        engine.detach(channel.equalizer)
        engine.detach(channel.volumeNode)
    }

    private func stopEngineIfIdleLocked() {
        guard channels.isEmpty else {
            return
        }

        stopBackgroundKeepAliveLocked()

        if engine.isRunning {
            engine.stop()
            NSLog("AudioMixerController: engine stopped because all sources disconnected")
            onStatusMessage?("Audio session active. Waiting for sources.")
        }
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

        let engineConfigurationToken = center.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleEngineConfigurationChange()
        }

        let mediaServicesResetToken = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.handleMediaServicesReset()
        }

        notificationTokens.append(interruptionToken)
        notificationTokens.append(routeChangeToken)
        notificationTokens.append(engineConfigurationToken)
        notificationTokens.append(mediaServicesResetToken)
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

    private func handleEngineConfigurationChange() {
        onStatusMessage?("Audio engine configuration changed. Reactivating playback.")
        reactivateSession(reason: "engine configuration changed")
    }

    private func handleMediaServicesReset() {
        onStatusMessage?("Audio services reset. Reactivating playback.")
        reactivateSession(reason: "media services reset")
    }

    private func reactivateSession(reason: String) {
        engineQueue.async {
            do {
                try self.configureSession()

                try self.ensureEngineRunningLocked(reason: reason)

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
                        // Do not stop the player node on a transient underrun.
                        // Keeping the node in the playing state lets newly scheduled
                        // buffers resume immediately, and the background keep-alive
                        // node keeps the audio engine active while the app is in the
                        // background.
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
        guard channelCount > 0, payload.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            return nil
        }

        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount >= channelCount, sampleCount.isMultiple(of: channelCount) else {
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
                    let normalized = max(-1.0, Float(samples[sampleIndex]) / 32768.0)
                    floatChannels[channel][frame] = normalized
                }
            }
        }

        return buffer
    }
}
