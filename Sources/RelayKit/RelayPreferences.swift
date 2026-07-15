import Foundation

/// Non-secret user preferences (DeepSeek model string). Persisted as JSON
/// next to routing state — not Keychain.
public struct RelayPreferences: Codable, Equatable {
    public var deepSeekModelString: String

    public init(deepSeekModelString: String = AppSupport.defaultModelString) {
        self.deepSeekModelString = deepSeekModelString
    }
}

public struct RelayPreferencesStore {
    private let fileURL: URL

    public init(fileURL: URL = RelayPreferencesStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        AppSupport.defaultDirectory().appendingPathComponent("preferences.json")
    }

    public func load() -> RelayPreferences {
        guard let data = try? Data(contentsOf: fileURL) else {
            return RelayPreferences()
        }
        return (try? JSONDecoder().decode(RelayPreferences.self, from: data)) ?? RelayPreferences()
    }

    public func save(_ preferences: RelayPreferences) throws {
        try AppSupport.ensureDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        try data.write(to: fileURL, options: .atomic)
    }
}
