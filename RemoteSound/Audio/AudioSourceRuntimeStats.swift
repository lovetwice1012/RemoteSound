import Foundation

struct AudioSourceRuntimeStats: Sendable {
    let queuedBufferCount: Int
    let droppedFrameCount: Int
    let isActivelyPlaying: Bool
}
