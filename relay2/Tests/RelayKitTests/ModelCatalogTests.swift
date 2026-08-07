import XCTest
@testable import RelayKit

final class ModelCatalogTests: XCTestCase {
    // MARK: - DeepSeek

    func testDeepSeekAppliesPrefix() throws {
        let json = #"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"}]}"#
        let models = try ModelCatalogClient.parseModels(provider: .deepSeek, from: Data(json.utf8))
        XCTAssertEqual(models, ["deepseek/deepseek-chat", "deepseek/deepseek-reasoner"])
    }

    func testDeepSeekDedupesRepeatedIds() throws {
        let json = #"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-chat"}]}"#
        let models = try ModelCatalogClient.parseModels(provider: .deepSeek, from: Data(json.utf8))
        XCTAssertEqual(models, ["deepseek/deepseek-chat"])
    }

    // MARK: - Anthropic

    func testAnthropicAppliesPrefix() throws {
        let json = #"{"data":[{"id":"claude-sonnet-5-20250929","display_name":"Claude Sonnet 5"},{"id":"claude-opus-4-8-20251101","display_name":"Claude Opus 4.8"}]}"#
        let models = try ModelCatalogClient.parseModels(provider: .anthropic, from: Data(json.utf8))
        XCTAssertEqual(models, ["anthropic/claude-sonnet-5-20250929", "anthropic/claude-opus-4-8-20251101"])
    }

    // MARK: - OpenAI

    func testOpenAIFiltersToChatCapableModelsOnly() throws {
        let json = #"""
        {"data":[
            {"id":"gpt-5.2"},
            {"id":"o4-mini"},
            {"id":"text-embedding-3-small"},
            {"id":"whisper-1"},
            {"id":"dall-e-3"},
            {"id":"gpt-3.5-turbo-instruct"}
        ]}
        """#
        let models = try ModelCatalogClient.parseModels(provider: .openAI, from: Data(json.utf8))
        XCTAssertEqual(models, ["openai/gpt-5.2", "openai/o4-mini"])
        XCTAssertFalse(models.contains("openai/text-embedding-3-small"))
        XCTAssertFalse(models.contains("openai/whisper-1"))
        XCTAssertFalse(models.contains("openai/dall-e-3"))
        XCTAssertFalse(models.contains("openai/gpt-3.5-turbo-instruct"))
    }

    func testOpenAIKeepsChatGPTAndOSeriesPrefixes() throws {
        let json = #"{"data":[{"id":"chatgpt-4o-latest"},{"id":"o1-preview"},{"id":"o3-mini"}]}"#
        let models = try ModelCatalogClient.parseModels(provider: .openAI, from: Data(json.utf8))
        XCTAssertEqual(models, ["openai/chatgpt-4o-latest", "openai/o1-preview", "openai/o3-mini"])
    }

    // MARK: - Gemini

    func testGeminiKeepsOnlyGenerateContentAndStripsModelsPrefix() throws {
        let json = #"""
        {"models":[
            {"name":"models/gemini-2.5-pro","supportedGenerationMethods":["generateContent","countTokens"]},
            {"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},
            {"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}
        ]}
        """#
        let models = try ModelCatalogClient.parseModels(provider: .gemini, from: Data(json.utf8))
        XCTAssertEqual(models, ["gemini/gemini-2.5-pro", "gemini/gemini-2.5-flash"])
    }

    // MARK: - Malformed / empty payloads throw

    func testEmptyDataArrayThrows() {
        let json = #"{"data":[]}"#
        XCTAssertThrowsError(try ModelCatalogClient.parseModels(provider: .deepSeek, from: Data(json.utf8)))
    }

    func testMalformedJSONThrows() {
        let json = "not json at all"
        XCTAssertThrowsError(try ModelCatalogClient.parseModels(provider: .anthropic, from: Data(json.utf8)))
    }

    func testMissingExpectedKeyThrows() {
        let json = #"{"unexpected":"shape"}"#
        XCTAssertThrowsError(try ModelCatalogClient.parseModels(provider: .openAI, from: Data(json.utf8)))
    }

    func testOpenAIFilteringResultingInNoChatModelsThrows() {
        // All entries are non-chat, so the filtered list is empty.
        let json = #"{"data":[{"id":"text-embedding-3-small"},{"id":"whisper-1"}]}"#
        XCTAssertThrowsError(try ModelCatalogClient.parseModels(provider: .openAI, from: Data(json.utf8)))
    }

    func testGeminiWithNoGenerateContentModelsThrows() {
        let json = #"{"models":[{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]}]}"#
        XCTAssertThrowsError(try ModelCatalogClient.parseModels(provider: .gemini, from: Data(json.utf8)))
    }
}
