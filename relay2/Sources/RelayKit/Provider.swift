import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case deepSeek
    case anthropic
    case openAI
    case gemini

    public var displayName: String {
        switch self {
        case .deepSeek: "DeepSeek"
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    public var envVar: String {
        switch self {
        case .deepSeek: "DEEPSEEK_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }

    public var keychainKey: RelayKeychainKey {
        switch self {
        case .deepSeek: .deepSeekAPIKey
        case .anthropic: .anthropicAPIKey
        case .openAI: .openAIAPIKey
        case .gemini: .geminiAPIKey
        }
    }

    /// LiteLLM-qualified model string for the provider's recommended model.
    public var defaultModel: String {
        switch self {
        case .deepSeek: "deepseek/deepseek-v4-pro"
        case .anthropic: "anthropic/claude-sonnet-5-20250929"
        case .openAI: "openai/gpt-5.2"
        case .gemini: "gemini/gemini-2.5-pro"
        }
    }

    public var modelOptions: [String] {
        switch self {
        case .deepSeek:
            ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash"]
        case .anthropic:
            ["anthropic/claude-sonnet-5-20250929", "anthropic/claude-opus-4-8-20251101"]
        case .openAI:
            ["openai/gpt-5.2", "openai/gpt-5.2-codex", "openai/o4-mini"]
        case .gemini:
            ["gemini/gemini-2.5-pro", "gemini/gemini-2.5-flash"]
        }
    }

    public var hasBalance: Bool {
        switch self {
        case .deepSeek: true
        default: false
        }
    }

    /// Human-readable short label for the model (drops provider prefix).
    /// E.g. "deepseek/deepseek-v4-pro" → "V4 Pro"
    public static func shortModelLabel(_ model: String) -> String {
        let suffix = model.split(separator: "/").last.map(String.init) ?? model
        return suffix
            .replacingOccurrences(of: "deepseek-", with: "")
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "GPT ")
            .replacingOccurrences(of: "gemini-", with: "")
            .replacingOccurrences(of: "o4-", with: "O4 ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
