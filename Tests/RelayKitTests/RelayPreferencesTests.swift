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
        XCTAssertEqual(prefs.deepSeekModelString, "deepseek/deepseek-v4-pro")
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)

        let original = RelayPreferences(deepSeekModelString: "custom/model-v1")
        try store.save(original)

        let loaded = store.load()
        XCTAssertEqual(loaded.deepSeekModelString, "custom/model-v1")
    }

    func testSaveCreatesDirectoryIfNeeded() throws {
        let nestedUrl = tempDir
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: nestedUrl)

        let prefs = RelayPreferences(deepSeekModelString: "test/model")
        try store.save(prefs)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedUrl.path))
        let loaded = store.load()
        XCTAssertEqual(loaded.deepSeekModelString, "test/model")
    }

    func testLoadCorruptJsonFallsBackToDefaults() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try "{ invalid json ]".write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let prefs = store.load()
        XCTAssertEqual(prefs.deepSeekModelString, "deepseek/deepseek-v4-pro")
    }

    func testLoadEmptyFileReturnsDefaults() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        try "".write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let prefs = store.load()
        XCTAssertEqual(prefs.deepSeekModelString, "deepseek/deepseek-v4-pro")
    }

    func testRelayPreferencesEquatable() {
        let prefs1 = RelayPreferences(deepSeekModelString: "model/a")
        let prefs2 = RelayPreferences(deepSeekModelString: "model/a")
        let prefs3 = RelayPreferences(deepSeekModelString: "model/b")

        XCTAssertEqual(prefs1, prefs2)
        XCTAssertNotEqual(prefs1, prefs3)
    }

    func testRelayPreferencesCodable() throws {
        let original = RelayPreferences(deepSeekModelString: "test/codec")
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RelayPreferences.self, from: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testLoadPreservesCustomValue() throws {
        let url = tempDir.appendingPathComponent("preferences.json")
        let store = RelayPreferencesStore(fileURL: url)

        let custom = RelayPreferences(deepSeekModelString: "deepseek/deepseek-v7-ultra")
        try store.save(custom)

        let store2 = RelayPreferencesStore(fileURL: url)
        let loaded = store2.load()
        XCTAssertEqual(loaded.deepSeekModelString, "deepseek/deepseek-v7-ultra")
    }

    func testDefaultModelOptionsIncludesProAndFlash() {
        let prefs = RelayPreferences()
        XCTAssertEqual(prefs.deepSeekModelOptions, ["deepseek/deepseek-v4-pro", "deepseek/deepseek-v4-flash"])
    }

    func testDecodingPreUpgradeJSONWithoutModelOptionsFillsInDefaults() throws {
        // Simulates a preferences.json written before deepSeekModelOptions existed.
        let url = tempDir.appendingPathComponent("preferences.json")
        try #"{"deepSeekModelString":"deepseek/deepseek-v7-ultra"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let store = RelayPreferencesStore(fileURL: url)
        let loaded = store.load()
        XCTAssertEqual(loaded.deepSeekModelString, "deepseek/deepseek-v7-ultra")
        XCTAssertEqual(loaded.deepSeekModelOptions, AppSupport.defaultModelOptions)
    }

    func testDefaultProxyPortIs4000() {
        XCTAssertEqual(RelayPreferences().proxyPort, 4000)
    }

    func testDecodingPreUpgradeJSONWithoutProxyPortFillsInDefault() throws {
        // Simulates a preferences.json written before proxyPort existed.
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
}
