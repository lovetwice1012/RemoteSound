import Foundation

@MainActor
final class SourceSettingsStore {
    private let defaults: UserDefaults
    private let storageKey = "RemoteSound.SourceSettings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func settings(for stableID: String) -> StoredSourceSettings? {
        allSettings()[stableID]
    }

    func save(_ settings: StoredSourceSettings, for stableID: String) {
        var current = allSettings()
        current[stableID] = settings

        persist(current)
    }

    func remove(stableID: String) {
        var current = allSettings()
        current.removeValue(forKey: stableID)

        persist(current)
    }

    private func persist(_ current: [String: StoredSourceSettings]) {
        guard let data = try? JSONEncoder().encode(current) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }

    private func allSettings() -> [String: StoredSourceSettings] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: StoredSourceSettings].self, from: data) else {
            return [:]
        }

        return decoded
    }
}
