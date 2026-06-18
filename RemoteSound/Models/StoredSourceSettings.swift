import Foundation

struct StoredSourceSettings: Codable {
    var isEnabled: Bool
    var volume: Double
    var lowGain: Double
    var midGain: Double
    var highGain: Double
}
