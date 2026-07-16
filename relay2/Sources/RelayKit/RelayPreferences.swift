import Foundation

/// Non-secret user preferences. Persisted as JSON next to routing state — not Keychain.
public struct RelayPreferences: Codable, Equatable {
    public var activeProvider: Provider
    /// Selected model per provider, e.g. ["deepSeek": "deepseek/deepseek-v4-pro"]
    public var providerModels: [Provider: String]
    /// Model options per provider (populated from Provider.modelOptions on first save).
    public var providerModelOptions: [Provider: [String]]
    public var proxyPort: Int
    /// Vision model for the Groq image→text preprocessor (not a routing provider).
    public var groqModelString: String

    public init(
        activeProvider: Provider = .deepSeek,
        providerModels: [Provider: String] = [:],
        providerModelOptions: [Provider: [String]] = [:],
        proxyPort: Int = AppSupport.defaultPort,
        groqModelString: String = AppSupport.defaultGroqModelString
    ) {
        self.activeProvider = activeProvider
        self.providerModels = providerModels
        self.providerModelOptions = providerModelOptions
        self.proxyPort = proxyPort
        self.groqModelString = groqModelString
    }

    /// Returns the selected model for `activeProvider`, falling back to the provider's default.
    public func activeModel() -> String {
        providerModels[activeProvider] ?? activeProvider.defaultModel
    }

    /// Returns model options for `activeProvider`, falling back to the provider's built-in list.
    public func activeModelOptions() -> [String] {
        providerModelOptions[activeProvider] ?? activeProvider.modelOptions
    }

    private enum CodingKeys: String, CodingKey {
        case activeProvider, providerModels, providerModelOptions, proxyPort, groqModelString
        // Legacy keys for migration
        case deepSeekModelString, deepSeekModelOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        activeProvider = try container.decodeIfPresent(Provider.self, forKey: .activeProvider) ?? .deepSeek
        providerModels = try container.decodeIfPresent([Provider: String].self, forKey: .providerModels) ?? [:]
        providerModelOptions = try container.decodeIfPresent([Provider: [String]].self, forKey: .providerModelOptions) ?? [:]
        proxyPort = try container.decodeIfPresent(Int.self, forKey: .proxyPort) ?? AppSupport.defaultPort
        groqModelString = try container.decodeIfPresent(String.self, forKey: .groqModelString) ?? AppSupport.defaultGroqModelString

        // Migrate legacy DeepSeek-only preferences.json → providerModels format
        if let legacyModel = try container.decodeIfPresent(String.self, forKey: .deepSeekModelString) {
            if providerModels[.deepSeek] == nil {
                providerModels[.deepSeek] = legacyModel
            }
        }
        if let legacyOptions = try container.decodeIfPresent([String].self, forKey: .deepSeekModelOptions) {
            if providerModelOptions[.deepSeek] == nil {
                providerModelOptions[.deepSeek] = legacyOptions
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeProvider, forKey: .activeProvider)
        try container.encode(providerModels, forKey: .providerModels)
        try container.encode(providerModelOptions, forKey: .providerModelOptions)
        try container.encode(proxyPort, forKey: .proxyPort)
        try container.encode(groqModelString, forKey: .groqModelString)
        // Legacy keys intentionally omitted — we always write the new format.
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
