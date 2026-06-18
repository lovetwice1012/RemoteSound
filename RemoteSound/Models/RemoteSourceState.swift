import Foundation

struct RemoteSourceState: Identifiable, Hashable {
    let id: UUID
    var stableID: String
    var name: String
    var endpointDescription: String
    var connectedAt: Date
    var isEnabled: Bool
    var volume: Double
    var lowGain: Double
    var midGain: Double
    var highGain: Double
    var sampleRate: Double
    var codec: String
    var receivedFrameCount: Int
    var droppedFrameCount: Int
    var queuedBufferCount: Int
    var isActivelyPlaying: Bool
    var lastFrameAt: Date?

    static func makeDefault(from descriptor: SourceDescriptor) -> RemoteSourceState {
        RemoteSourceState(
            id: descriptor.id,
            stableID: descriptor.stableID,
            name: descriptor.name,
            endpointDescription: descriptor.endpointDescription,
            connectedAt: Date(),
            isEnabled: true,
            volume: 1.0,
            lowGain: 0.0,
            midGain: 0.0,
            highGain: 0.0,
            sampleRate: descriptor.sampleRate,
            codec: descriptor.codec,
            receivedFrameCount: 0,
            droppedFrameCount: 0,
            queuedBufferCount: 0,
            isActivelyPlaying: false,
            lastFrameAt: nil
        )
    }
}
