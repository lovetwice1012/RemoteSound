import Foundation

struct ClientHello: Codable {
    let type: String
    let name: String
    let clientID: String?
    let sampleRate: Double
    let channels: Int
    let codec: String
    let frameSamples: Int
}

struct ServerEvent: Codable {
    let type: String
    let message: String
    let sourceID: String?
}

struct SourceDescriptor: Sendable {
    let id: UUID
    var name: String
    var stableID: String
    var endpointDescription: String
    var sampleRate: Double
    var channels: Int
    var codec: String
}
