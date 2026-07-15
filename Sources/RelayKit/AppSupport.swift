import Foundation

/// Default locations under `~/Library/Application Support/Relay/`.
/// Every path-taking type also accepts an injectable override for tests.
public enum AppSupport {
    public static let directoryName = "Relay"
    public static let defaultPort = 4000
    public static let deepSeekAPIKeyEnvVar = "DEEPSEEK_API_KEY"
    public static let masterKeyEnvVar = "LITELLM_MASTER_KEY"
    public static let defaultModelString = "deepseek/deepseek-v4-pro"
    public static let baseURL = "http://127.0.0.1:4000"

    public static func defaultDirectory() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(directoryName)", isDirectory: true)
    }

    public static func ensureDirectory(_ url: URL = defaultDirectory()) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
