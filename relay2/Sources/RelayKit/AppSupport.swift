import Foundation

/// Default locations under `~/Library/Application Support/Relay2/`.
/// Every path-taking type also accepts an injectable override for tests.
public enum AppSupport {
    public static let directoryName = "Relay2"
    public static let defaultPort = 4000
    public static let masterKeyEnvVar = "LITELLM_MASTER_KEY"

    // Groq vision (image → text describe) — a global preprocessor in front of
    // whichever provider is active, not a routing provider itself.
    public static let groqAPIKeyEnvVar = "GROQ_API_KEY"
    public static let groqVisionModelEnvVar = "GROQ_VISION_MODEL"
    public static let defaultGroqModelString = "meta-llama/llama-4-scout-17b-16e-instruct"
    public static let groqVisionCallbackModule = "groq_vision_callback"

    public static func baseURL(port: Int = defaultPort) -> String {
        "http://127.0.0.1:\(port)"
    }

    public static func defaultDirectory() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(directoryName)", isDirectory: true)
    }

    public static func ensureDirectory(_ url: URL = defaultDirectory()) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
