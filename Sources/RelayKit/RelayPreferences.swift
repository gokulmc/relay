import Foundation

/// Non-secret user preferences (DeepSeek model string). Persisted as JSON
/// next to routing state — not Keychain.
public struct RelayPreferences: Codable, Equatable {
    public var deepSeekModelString: String
    public var deepSeekModelOptions: [String]
    public var proxyPort: Int
    public var groqModelString: String

    public init(
        deepSeekModelString: String = AppSupport.defaultModelString,
        deepSeekModelOptions: [String] = AppSupport.defaultModelOptions,
        proxyPort: Int = AppSupport.defaultPort,
        groqModelString: String = AppSupport.defaultGroqModelString
    ) {
        self.deepSeekModelString = deepSeekModelString
        self.deepSeekModelOptions = deepSeekModelOptions
        self.proxyPort = proxyPort
        self.groqModelString = groqModelString
    }

    private enum CodingKeys: String, CodingKey {
        case deepSeekModelString, deepSeekModelOptions, proxyPort, groqModelString
    }

    /// Custom decode so files saved before `deepSeekModelOptions`/`proxyPort`/`groqModelString`
    /// existed still load (falling back to defaults) instead of losing the saved model string.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deepSeekModelString = try container.decode(String.self, forKey: .deepSeekModelString)
        deepSeekModelOptions = try container.decodeIfPresent([String].self, forKey: .deepSeekModelOptions)
            ?? AppSupport.defaultModelOptions
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? AppSupport.defaultPort
        groqModelString = try container.decodeIfPresent(String.self, forKey: .groqModelString)
            ?? AppSupport.defaultGroqModelString
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
