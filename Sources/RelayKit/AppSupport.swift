import Foundation

/// Default locations under `~/Library/Application Support/Relay/`.
/// Every path-taking type also accepts an injectable override for tests.
public enum AppSupport {
    public static let directoryName = "Relay"
    public static let defaultPort = 4000
    public static let deepSeekAPIKeyEnvVar = "DEEPSEEK_API_KEY"
    public static let masterKeyEnvVar = "LITELLM_MASTER_KEY"
    public static let defaultModelString = "deepseek/deepseek-v4-pro"
    public static let defaultModelOptions = ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash"]

    // Groq vision (image → text describe, so DeepSeek can "see" images).
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
