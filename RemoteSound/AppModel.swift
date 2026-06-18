import AVFAudio
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    let serverPort: UInt16 = 8_765
    var serverMessage = "Starting audio engine..."
    var serverIsRunning = false
    var audioStatusMessage = "Preparing audio session..."
    var localAddresses: [String] = []
    var sources: [RemoteSourceState] = []
    var selectedSourceID: UUID?
    var selectedStableSourceID: String?

    private let mixer = AudioMixerController()
    private let settingsStore = SourceSettingsStore()
    private var server: WebSocketAudioServer?

    init() {
        server = WebSocketAudioServer(port: serverPort)
        localAddresses = LocalNetworkAddressProvider.ipv4Addresses()
        wireServerCallbacks()

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

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            mixer.reactivateIfNeeded(reason: "app became active")
        case .inactive:
            mixer.prepareForBackgroundPlayback()
        case .background:
            mixer.prepareForBackgroundPlayback()
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
        server?.disconnectSource(id: id)
    }

    private func applyEqualizer(for index: Int) {
        let source = sources[index]
        mixer.setEqualizer(low: source.lowGain, mid: source.midGain, high: source.highGain, for: source.id)
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

        do {
            try server?.start()
            serverIsRunning = true
            serverMessage = "Listening for WebSocket audio sources on port \(serverPort)."
            audioStatusMessage = "Audio session active."
        } catch {
            serverIsRunning = false
            let nsError = error as NSError
            serverMessage = "Server startup failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            audioStatusMessage = "Server failed: \(error.localizedDescription) (\(nsError.domain) code \(nsError.code))"
            NSLog("Server start error: %@", nsError)
        }
    }

    private func wireServerCallbacks() {
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

        server?.onServerStateChange = { [weak self] message in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.serverMessage = message
                let lowered = message.lowercased()
                self.serverIsRunning = !lowered.contains("failed") && !lowered.contains("stopped")
            }
        }

        server?.onSourceConnected = { [weak self] descriptor in
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

        server?.onSourceUpdated = { [weak self] descriptor in
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

        server?.onSourceDisconnected = { [weak self] id in
            Task { @MainActor in
                guard let self else {
                    return
                }

                mixer.unregisterSource(id: id)
                self.sources.removeAll(where: { $0.id == id })
                self.sortSources()
                self.refreshSelectionAfterSourceMutation(preferredSourceID: nil)
            }
        }

        server?.onAudioFrame = { [weak self] id, payload in
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
            server?.disconnectSource(id: duplicate.id)
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
