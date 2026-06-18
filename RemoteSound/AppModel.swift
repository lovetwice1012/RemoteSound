import AVFAudio
import Foundation
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    let serverPort: UInt16 = 8_765
    var serverMessage = "Starting audio engine..."
    var serverIsRunning = false
    var audioStatusMessage = "Preparing audio session..."
    var localAddresses: [String] = []
    var remoteURLString = UserDefaults.standard.string(forKey: "RemoteSound.RemoteURL") ?? "ws://192.168.1.10:8765/"
    var autoConnectDiscoveredSource = UserDefaults.standard.object(forKey: "RemoteSound.AutoConnectDiscoveredSource") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoConnectDiscoveredSource, forKey: "RemoteSound.AutoConnectDiscoveredSource")
            updateDiscoveryState()
        }
    }
    var discoveryMessage = "Discovery idle."
    var sources: [RemoteSourceState] = []
    var selectedSourceID: UUID?
    var selectedStableSourceID: String?

    private let mixer = AudioMixerController()
    private let settingsStore = SourceSettingsStore()
    private let client = WebSocketAudioClient()
    private let serviceBrowser = RemoteAudioServiceBrowser()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        wireClientCallbacks()
        wireDiscoveryCallbacks()

        Task {
            start()
        }
    }

    var selectedSource: RemoteSourceState? {
        if let selectedSourceID,
           let matched = sources.first(where: { $0.id == selectedSourceID }) {
            return matched
        }

        guard let selectedStableSourceID else {
            return nil
        }

        return sources.first(where: { $0.stableID == selectedStableSourceID })
    }

    func refreshAddresses() {
        localAddresses = LocalNetworkAddressProvider.ipv4Addresses()
    }

    func connectToRemoteSource() {
        let trimmedURL = remoteURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        remoteURLString = trimmedURL
        UserDefaults.standard.set(trimmedURL, forKey: "RemoteSound.RemoteURL")

        guard let url = URL(string: trimmedURL),
              url.scheme == "ws" || url.scheme == "wss" else {
            serverIsRunning = false
            serverMessage = "Enter a ws:// or wss:// URL for the Windows source."
            return
        }

        client.connect(to: url)
    }

    func disconnectRemoteSource() {
        client.disconnect()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        let backgroundTimeRemaining = UIApplication.shared.backgroundTimeRemaining
        NSLog(
            "AppModel.handleScenePhase: phase=%@ sources=%d backgroundTimeRemaining=%f",
            String(describing: phase),
            sources.count,
            backgroundTimeRemaining
        )

        switch phase {
        case .active:
            endBackgroundAudioTask()
            client.reconnectIfNeeded()
            client.logDebugState(reason: "scene became active")
            mixer.reactivateIfNeeded(reason: "app became active")
            mixer.logDebugState(reason: "scene became active")
        case .inactive:
            beginBackgroundAudioTaskIfNeeded()
            client.reconnectIfNeeded()
            client.logDebugState(reason: "scene became inactive")
            mixer.prepareForBackgroundPlayback()
            mixer.logDebugState(reason: "scene became inactive")
        case .background:
            beginBackgroundAudioTaskIfNeeded()
            client.reconnectIfNeeded()
            client.logDebugState(reason: "scene entered background")
            mixer.prepareForBackgroundPlayback()
            mixer.logDebugState(reason: "scene entered background")
        default:
            break
        }
    }

    func selectSource(id: UUID?) {
        selectedSourceID = id
        selectedStableSourceID = sources.first(where: { $0.id == id })?.stableID
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        sources[index].isEnabled = isEnabled
        mixer.setEnabled(isEnabled, for: id)
        persistSettings(for: index)
    }

    func setVolume(_ volume: Double, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        sources[index].volume = volume
        mixer.setVolume(volume, for: id)
        persistSettings(for: index)
    }

    func setLowGain(_ gain: Double, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        sources[index].lowGain = gain
        applyEqualizer(for: index)
        persistSettings(for: index)
    }

    func setMidGain(_ gain: Double, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        sources[index].midGain = gain
        applyEqualizer(for: index)
        persistSettings(for: index)
    }

    func setHighGain(_ gain: Double, for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        sources[index].highGain = gain
        applyEqualizer(for: index)
        persistSettings(for: index)
    }

    func resetSourceMix(for id: UUID) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            return
        }

        applyDefaultSettings(to: index)
        applySettingsToMixer(for: index)
        settingsStore.remove(stableID: sources[index].stableID)
    }

    func disconnectSource(id: UUID) {
        client.disconnectSource(id: id)
    }

    private func applyEqualizer(for index: Int) {
        let source = sources[index]
        mixer.setEqualizer(low: source.lowGain, mid: source.midGain, high: source.highGain, for: source.id)
    }

    private func beginBackgroundAudioTaskIfNeeded() {
        guard backgroundTaskID == .invalid, !sources.isEmpty else {
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RemoteSound background audio") { [weak self] in
            Task { @MainActor in
                NSLog("AppModel: background audio task expired")
                self?.endBackgroundAudioTask()
            }
        }
        NSLog("AppModel: background audio task started id=%@", String(describing: backgroundTaskID))
    }

    private func endBackgroundAudioTask() {
        guard backgroundTaskID != .invalid else {
            return
        }

        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        NSLog("AppModel: background audio task ended id=%@", String(describing: backgroundTaskID))
        backgroundTaskID = .invalid
    }

    private func start() {
        do {
            try mixer.start()
        } catch {
            serverIsRunning = false
            let nsError = error as NSError
            serverMessage = "Audio startup failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            audioStatusMessage = "Audio session failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            NSLog("Audio start error: %@", nsError)
            return
        }

        serverIsRunning = false
        serverMessage = "Ready to connect to a Windows audio source."
        audioStatusMessage = "Audio session active."
        updateDiscoveryState()
    }

    private func wireClientCallbacks() {
        let mixer = mixer

        mixer.onStatusMessage = { [weak self] message in
            Task { @MainActor in
                self?.audioStatusMessage = message
            }
        }

        mixer.onSourceStatsChanged = { [weak self] id, stats in
            Task { @MainActor in
                guard let self,
                      let index = self.sources.firstIndex(where: { $0.id == id }) else {
                    return
                }

                self.sources[index].queuedBufferCount = stats.queuedBufferCount
                self.sources[index].droppedFrameCount = stats.droppedFrameCount
                self.sources[index].isActivelyPlaying = stats.isActivelyPlaying
            }
        }

        client.onConnectionStateChange = { [weak self] message, isConnected in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.serverMessage = message
                self.serverIsRunning = isConnected
            }
        }

        client.onSourceConnected = { [weak self] descriptor in
            Task { @MainActor in
                guard let self else {
                    return
                }

                var source = RemoteSourceState.makeDefault(from: descriptor)
                self.restoreStoredSettings(into: &source)
                self.sources.append(source)
                self.sortSources()
                self.selectSourceIfNeeded(source)

                if let index = self.sources.firstIndex(where: { $0.id == descriptor.id }) {
                    self.applySettingsToMixer(for: index)
                }
            }
        }

        client.onSourceUpdated = { [weak self] descriptor in
            Task { @MainActor in
                guard let self,
                      let index = self.sources.firstIndex(where: { $0.id == descriptor.id }) else {
                    return
                }

                self.sources[index].name = descriptor.name
                self.sources[index].stableID = descriptor.stableID
                self.sources[index].endpointDescription = descriptor.endpointDescription
                self.sources[index].sampleRate = descriptor.sampleRate
                self.sources[index].channels = descriptor.channels
                self.sources[index].codec = descriptor.codec
                mixer.registerSource(id: descriptor.id, sampleRate: descriptor.sampleRate, channelCount: AVAudioChannelCount(descriptor.channels))
                self.restoreStoredSettingsIfNeeded(for: index)
                self.applySettingsToMixer(for: index)
                self.handleDuplicateStableSource(updatedSourceID: descriptor.id, stableID: descriptor.stableID)
                self.sortSources()
                self.refreshSelectionAfterSourceMutation(preferredSourceID: descriptor.id)
            }
        }

        client.onSourceDisconnected = { [weak self] id in
            Task { @MainActor in
                guard let self else {
                    return
                }

                mixer.unregisterSource(id: id)
                self.sources.removeAll(where: { $0.id == id })
                self.sortSources()
                self.refreshSelectionAfterSourceMutation(preferredSourceID: nil)
                if self.sources.isEmpty {
                    self.endBackgroundAudioTask()
                }
            }
        }

        client.onAudioFrame = { [weak self] id, payload in
            guard let self else {
                return
            }

            Task { @MainActor in
                guard let index = self.sources.firstIndex(where: { $0.id == id }) else {
                    return
                }

                self.sources[index].receivedFrameCount += 1
                self.sources[index].lastFrameAt = Date()
            }

            mixer.enqueuePCM16Frame(payload, for: id)
        }
    }

    private func wireDiscoveryCallbacks() {
        serviceBrowser.onStatusChange = { [weak self] message in
            Task { @MainActor in
                self?.discoveryMessage = message
            }
        }

        serviceBrowser.onServiceFound = { [weak self] url, name in
            Task { @MainActor in
                guard let self, self.autoConnectDiscoveredSource else {
                    return
                }

                if self.serverIsRunning, self.remoteURLString == url.absoluteString {
                    return
                }

                self.remoteURLString = url.absoluteString
                self.serverMessage = "Found \(name). Connecting..."
                self.connectToRemoteSource()
            }
        }
    }

    private func updateDiscoveryState() {
        if autoConnectDiscoveredSource {
            serviceBrowser.start()
        } else {
            serviceBrowser.stop()
        }
    }

    private func restoreStoredSettings(into source: inout RemoteSourceState) {
        guard let stored = settingsStore.settings(for: source.stableID) else {
            return
        }

        source.isEnabled = stored.isEnabled
        source.volume = stored.volume
        source.lowGain = stored.lowGain
        source.midGain = stored.midGain
        source.highGain = stored.highGain
    }

    private func restoreStoredSettingsIfNeeded(for index: Int) {
        let current = sources[index]
        guard let stored = settingsStore.settings(for: current.stableID) else {
            return
        }

        sources[index].isEnabled = stored.isEnabled
        sources[index].volume = stored.volume
        sources[index].lowGain = stored.lowGain
        sources[index].midGain = stored.midGain
        sources[index].highGain = stored.highGain
    }

    private func applySettingsToMixer(for index: Int) {
        let source = sources[index]
        mixer.setEnabled(source.isEnabled, for: source.id)
        mixer.setVolume(source.volume, for: source.id)
        mixer.setEqualizer(low: source.lowGain, mid: source.midGain, high: source.highGain, for: source.id)
    }

    private func applyDefaultSettings(to index: Int) {
        sources[index].isEnabled = true
        sources[index].volume = 1.0
        sources[index].lowGain = 0.0
        sources[index].midGain = 0.0
        sources[index].highGain = 0.0
    }

    private func persistSettings(for index: Int) {
        let source = sources[index]
        settingsStore.save(
            StoredSourceSettings(
                isEnabled: source.isEnabled,
                volume: source.volume,
                lowGain: source.lowGain,
                midGain: source.midGain,
                highGain: source.highGain
            ),
            for: source.stableID
        )
    }

    private func handleDuplicateStableSource(updatedSourceID: UUID, stableID: String) {
        let duplicates = sources.filter { $0.stableID == stableID && $0.id != updatedSourceID }
        guard !duplicates.isEmpty else {
            return
        }

        let shouldFollowUpdatedSource = duplicates.contains(where: { $0.id == selectedSourceID || $0.stableID == selectedStableSourceID })

        for duplicate in duplicates {
            client.disconnectSource(id: duplicate.id)
        }

        if shouldFollowUpdatedSource {
            selectedSourceID = updatedSourceID
            selectedStableSourceID = stableID
        }
    }

    private func selectSourceIfNeeded(_ source: RemoteSourceState) {
        if selectedSourceID == nil {
            selectedSourceID = source.id
        }

        if selectedStableSourceID == nil {
            selectedStableSourceID = source.stableID
        }
    }

    private func refreshSelectionAfterSourceMutation(preferredSourceID: UUID?) {
        if let preferredSourceID,
           let preferred = sources.first(where: { $0.id == preferredSourceID }) {
            selectedSourceID = preferred.id
            selectedStableSourceID = preferred.stableID
            return
        }

        if let selectedSourceID,
           let current = sources.first(where: { $0.id == selectedSourceID }) {
            selectedStableSourceID = current.stableID
            return
        }

        if let selectedStableSourceID,
           let matched = sources.first(where: { $0.stableID == selectedStableSourceID }) {
            self.selectedSourceID = matched.id
            return
        }

        selectedSourceID = sources.first?.id
        selectedStableSourceID = sources.first?.stableID
    }

    private func sortSources() {
        sources.sort {
            if $0.isActivelyPlaying != $1.isActivelyPlaying {
                return $0.isActivelyPlaying && !$1.isActivelyPlaying
            }

            if $0.name != $1.name {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            return $0.connectedAt < $1.connectedAt
        }
    }
}
