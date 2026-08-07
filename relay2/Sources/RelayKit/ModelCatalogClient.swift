import Foundation

// MARK: - Client

/// Fetches a provider's CURRENT model catalog straight from that provider's own API
/// (not LiteLLM), so a user can pick up newly released models without waiting for an
/// app update. Results are LiteLLM-qualified (provider-prefixed) to match `Provider.modelOptions`.
public struct ModelCatalogClient: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    public func fetchModels(for provider: Provider, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: Self.endpoint(for: provider, apiKey: apiKey))
        request.httpMethod = "GET"
        switch provider {
        case .deepSeek, .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            break // key travels in the query string
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ModelCatalogError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ModelCatalogError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ModelCatalogError.httpError(http.statusCode, body)
        }
        return try Self.parseModels(provider: provider, from: data)
    }

    private static func endpoint(for provider: Provider, apiKey: String) -> URL {
        switch provider {
        case .deepSeek:
            return URL(string: "https://api.deepseek.com/models")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/models")!
        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            return components.url!
        }
    }

    // MARK: - Response parsing (pure, testable — no network involved)

    /// Decodes a provider's raw model-list response body into LiteLLM-qualified,
    /// deduped model ids. Throws on empty or malformed payloads rather than
    /// returning a partial/junk list.
    public static func parseModels(provider: Provider, from data: Data) throws -> [String] {
        switch provider {
        case .deepSeek:
            let ids = try decode(IDListResponse.self, from: data).data.map(\.id)
            return try dedupe(ids.map { "deepseek/" + $0 })
        case .anthropic:
            let ids = try decode(IDListResponse.self, from: data).data.map(\.id)
            return try dedupe(ids.map { "anthropic/" + $0 })
        case .openAI:
            let ids = try decode(IDListResponse.self, from: data).data.map(\.id)
            return try dedupe(ids.filter(isChatCapableOpenAIModel).map { "openai/" + $0 })
        case .gemini:
            let models = try decode(GeminiListResponse.self, from: data).models
            let ids = models
                .filter { $0.supportedGenerationMethods.contains("generateContent") }
                .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst("models/".count)) : $0.name }
            return try dedupe(ids.map { "gemini/" + $0 })
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ModelCatalogError.badResponse
        }
    }

    /// Dedupes while preserving the provider's own ordering; throws if nothing survives.
    private static func dedupe(_ ids: [String]) throws -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for id in ids where !id.isEmpty {
            if seen.insert(id).inserted {
                result.append(id)
            }
        }
        guard !result.isEmpty else { throw ModelCatalogError.emptyResponse }
        return result
    }

    /// OpenAI's `/v1/models` lists every model on the account, including
    /// non-chat ones (embeddings, audio, image, moderation) — keep only chat-capable ids.
    private static func isChatCapableOpenAIModel(_ id: String) -> Bool {
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt"]
        guard chatPrefixes.contains(where: { id.hasPrefix($0) }) else { return false }
        let nonChatMarkers = [
            "embedding", "whisper", "tts", "dall-e", "audio",
            "image", "moderation", "transcribe", "realtime", "-instruct",
        ]
        return !nonChatMarkers.contains { id.contains($0) }
    }
}

// MARK: - Response shapes

/// Shared shape for DeepSeek/OpenAI/Anthropic: `{"data":[{"id":"..."}]}`.
private struct IDListResponse: Decodable {
    struct Item: Decodable { let id: String }
    let data: [Item]
}

private struct GeminiListResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let supportedGenerationMethods: [String]
    }
    let models: [Model]
}

// MARK: - Errors

public enum ModelCatalogError: Error, CustomStringConvertible, LocalizedError {
    case badResponse
    case httpError(Int, String)
    case emptyResponse
    case networkError(String)

    public var description: String {
        switch self {
        case .badResponse:
            return "Invalid response from the provider's model API."
        case .httpError(let code, let body):
            return "Model list request returned \(code): \(body)"
        case .emptyResponse:
            return "Provider returned no usable models."
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}
