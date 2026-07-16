import XCTest
@testable import RelayKit

final class RelayPreferencesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-prefs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadWithNoFileReturnsDefaults() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)
        let prefs = store.load()
        XCTAssertEqual(prefs.activeProvider, .deepSeek)
        XCTAssertEqual(prefs.activeModel(), Provider.deepSeek.defaultModel)
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)

        var original = RelayPreferences()
        original.providerModels[.deepSeek] = "custom/model-v1"
        try store.save(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.providerModels[.deepSeek], "custom/model-v1")
    }

    func testSaveCreatesDirectoryIfNeeded() throws {
        let nestedUrl = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: nestedUrl)

        var prefs = RelayPreferences()
        prefs.providerModels[.deepSeek] = "test/model"
        try store.save(prefs)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedUrl.path))
        let loaded = store.load()
        XCTAssertEqual(loaded.providerModels[.deepSeek], "test/model")
    }

    func testLoadCorruptJsonFallsBackToDefaults() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try "{ invalid json ]".write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let prefs = store.load()
        XCTAssertEqual(prefs.activeProvider, .deepSeek)
    }

    func testLoadEmptyFileReturnsDefaults() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let prefs = store.load()
        XCTAssertEqual(prefs.activeProvider, .deepSeek)
    }

    func testRelayPreferencesEquatable() {
        var prefs1 = RelayPreferences()
        prefs1.providerModels[.deepSeek] = "model/a"
        var prefs2 = RelayPreferences()
        prefs2.providerModels[.deepSeek] = "model/a"
        var prefs3 = RelayPreferences()
        prefs3.providerModels[.deepSeek] = "model/b"

        XCTAssertEqual(prefs1, prefs2)
        XCTAssertNotEqual(prefs1, prefs3)
    }

    func testRelayPreferencesCodable() throws {
        var original = RelayPreferences()
        original.providerModels[.anthropic] = "anthropic/claude-sonnet-5"
        original.providerModelOptions[.deepSeek] = ["deepseek/deepseek-v4-pro"]
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RelayPreferences.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testLoadPreservesCustomValue() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)

        var custom = RelayPreferences()
        custom.providerModels[.deepSeek] = "deepseek/deepseek-v7-ultra"
        try store.save(custom)

        let store2 = RelayPreferencesStore(fileURL: url)
        let loaded = store2.load()
        XCTAssertEqual(loaded.providerModels[.deepSeek], "deepseek/deepseek-v7-ultra")
    }

    func testActiveModelOptionsUsesProviderDefaults() {
        let prefs = RelayPreferences()
        XCTAssertEqual(prefs.activeModelOptions(), Provider.deepSeek.modelOptions)
    }

    func testActiveModelOptionsReturnsCustomOptions() {
        var prefs = RelayPreferences()
        let custom = ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash", "deepseek/deepseek-custom"]
        prefs.providerModelOptions[.deepSeek] = custom
        XCTAssertEqual(prefs.activeModelOptions(), custom)
    }

    func testDecodingLegacyDeepSeekJSONMigratesToProviderModels() throws {
        // Simulates a preferences.json written by Relay v1 (DeepSeek-only).
        let url = tempDir.appendingPathComponent("preferences.json")
        try #"{"deepSeekModelString":"deepseek/deepseek-v7-ultra"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let loaded = store.load()
        XCTAssertEqual(loaded.providerModels[.deepSeek], "deepseek/deepseek-v7-ultra")
        XCTAssertEqual(loaded.activeModel(), "deepseek/deepseek-v7-ultra")
    }

    func testDecodingLegacyJSONWithModelOptionsMigratesBoth() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try #"{"deepSeekModelString":"deepseek/deepseek-v4-pro","deepSeekModelOptions":["deepseek/deepseek-v4-pro","deepseek/deepseek-v4-flash"]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let loaded = store.load()
        XCTAssertEqual(loaded.providerModels[.deepSeek], "deepseek/deepseek-v4-pro")
        XCTAssertEqual(loaded.providerModelOptions[.deepSeek], ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash"])
    }

    func testDefaultProxyPortIs4000() {
        XCTAssertEqual(RelayPreferences().proxyPort, 4000)
    }

    func testDecodingLegacyJSONWithoutProxyPortFillsInDefault() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try #"{"deepSeekModelString":"deepseek/deepseek-v4-pro","deepSeekModelOptions":["deepseek/deepseek-v4-pro"]}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let loaded = store.load()
        XCTAssertEqual(loaded.proxyPort, AppSupport.defaultPort)
    }

    func testSaveAndLoadRoundTripsCustomPort() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)

        var prefs = RelayPreferences()
        prefs.proxyPort = 4010
        try store.save(prefs)

        XCTAssertEqual(store.load().proxyPort, 4010)
    }

    func testActiveModelFallsBackToDefaultWhenNotSet() {
        let prefs = RelayPreferences()
        XCTAssertEqual(prefs.activeModel(), Provider.deepSeek.defaultModel)
    }

    func testSwitchActiveProviderPreservesModelPerProvider() {
        var prefs = RelayPreferences()
        prefs.providerModels[.deepSeek] = "deepseek/deepseek-v4-flash"
        prefs.providerModels[.anthropic] = "anthropic/claude-opus-4-8"
        prefs.activeProvider = .anthropic
        XCTAssertEqual(prefs.activeModel(), "anthropic/claude-opus-4-8")
        prefs.activeProvider = .deepSeek
        XCTAssertEqual(prefs.activeModel(), "deepseek/deepseek-v4-flash")
    }
}
