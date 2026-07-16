import Foundation

// MARK: - API types

private struct GroqRequest: Encodable {
    let model: String
    let messages: [GroqMessage]
    let temperature: Double
    let max_tokens: Int
}

private struct GroqMessage: Encodable {
    let role: String
    let content: [GroqContentBlock]
}

private enum GroqContentBlock: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let dataURL):
            try container.encode("image_url", forKey: .type)
            var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .imageUrl)
            try nested.encode(dataURL, forKey: .url)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, imageUrl = "image_url"
    }
    enum ImageKeys: String, CodingKey {
        case url
    }
}

private struct GroqResponse: Decodable {
    let choices: [GroqChoice]
}

private struct GroqChoice: Decodable {
    let message: GroqResponseMessage
}

private struct GroqResponseMessage: Decodable {
    let content: String
}

// MARK: - Client

/// Calls Groq's vision-capable chat completions endpoint.
public struct GroqVisionClient: Sendable {
    private let apiKey: String
    private let model: String
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = AppSupport.defaultGroqModelString,
        timeout: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: config)
    }

    /// Send image data with a prompt to Groq and return the text description.
    public func describe(imageData: Data, prompt: String) async throws -> String {
        let b64 = imageData.base64EncodedString()
        let dataURL = "data:image/png;base64,\(b64)"

        let request = GroqRequest(
            model: model,
            messages: [
                GroqMessage(role: "user", content: [
                    .text(prompt),
                    .imageURL(dataURL),
                ]),
            ],
            temperature: 0.5,
            max_tokens: 2048
        )

        var httpReq = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        httpReq.httpMethod = "POST"
        httpReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpReq.httpBody = try JSONEncoder().encode(request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: httpReq)
        } catch {
            throw GroqVisionError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GroqVisionError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GroqVisionError.httpError(http.statusCode, body)
        }
        let decoded = try JSONDecoder().decode(GroqResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw GroqVisionError.emptyResponse
        }
        return text
    }
}

// MARK: - Prompts

extension GroqVisionClient {
    /// Predefined vision prompts matching clipboard-vision-mcp.
    public static let prompts: [String: String] = [
        "analyze": "Describe this image in detail. Identify all relevant elements, context, and anything that would help someone who cannot see it.",
        "extract_text": "Extract ALL text from this image. Return only the text, preserving layout and line breaks. No commentary.",
        "describe_ui": "Analyze this UI screenshot. Describe: 1) overall layout, 2) components (buttons, forms, navigation, inputs), 3) visible text and labels, 4) state (errors, active tabs, modals).",
        "diagnose_error": "Analyze this error screenshot. Return: 1) the exact error message, 2) the likely cause, 3) concrete steps to fix it, 4) how to prevent recurrence.",
        "understand_diagram": "Interpret this diagram. Return: 1) diagram type, 2) components and their roles, 3) relationships/flow, 4) the overall purpose.",
        "analyze_chart": "Analyze this chart. Return: 1) chart type, 2) axes and labels, 3) key trends, 4) notable data points, 5) insights.",
        "code_from_screenshot": "Extract all code from this screenshot. Return: 1) language, 2) clean code in a fenced code block preserving indentation.",
    ]

    /// Convenience: describe using a named prompt key.
    public func describe(imageData: Data, promptKey: String, overridePrompt: String? = nil) async throws -> String {
        let prompt = overridePrompt ?? Self.prompts[promptKey] ?? Self.prompts["analyze"]!
        return try await describe(imageData: imageData, prompt: prompt)
    }
}

// MARK: - Errors

public enum GroqVisionError: Error, CustomStringConvertible, LocalizedError {
    case badResponse
    case httpError(Int, String)
    case emptyResponse
    case networkError(String)

    public var description: String {
        switch self {
        case .badResponse:
            return "Invalid response from Groq API."
        case .httpError(let code, let body):
            return "Groq API returned \(code): \(body)"
        case .emptyResponse:
            return "Groq API returned an empty response."
        case .networkError(let msg):
            return "Network error: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}
