import AVFoundation
import Foundation

@MainActor
final class HLSAudioPlayer {
    var onStatusMessage: ((String, Bool) -> Void)?

    private var player: AVPlayer?
    private var timeControlObservation: NSKeyValueObservation?

    func play(url: URL) {
        stop()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            onStatusMessage?("Audio session failed: \(error.localizedDescription)", false)
            return
        }

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 6

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                switch player.timeControlStatus {
                case .playing:
                    self?.onStatusMessage?("Playing reliable HLS stream.", true)
                case .waitingToPlayAtSpecifiedRate:
                    self?.onStatusMessage?("Buffering reliable HLS stream...", true)
                case .paused:
                    self?.onStatusMessage?("Reliable stream paused.", false)
                @unknown default:
                    self?.onStatusMessage?("Reliable stream status changed.", false)
                }
            }
        }

        onStatusMessage?("Opening reliable HLS stream...", true)
        player.play()
    }

    func reactivate() {
        guard let player else {
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            onStatusMessage?("Audio session recovery failed: \(error.localizedDescription)", false)
            return
        }

        player.play()
    }

    func stop() {
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        player?.pause()
        player = nil
        onStatusMessage?("Reliable stream stopped.", false)
    }
}
