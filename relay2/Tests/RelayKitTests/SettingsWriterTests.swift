import XCTest
@testable import RelayKit

final class SettingsWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSettingsBackupCreatesTimestampedCopy() throws {
        let source = tempDir.appendingPathComponent("settings.json")
        try #"{"a":1}"#.write(to: source, atomically: true, encoding: .utf8)
        let backup = SettingsBackup(appSupportDir: tempDir)
        let dest = try backup.backup(sourceURL: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), #"{"a":1}"#)
        XCTAssertTrue(dest.lastPathComponent.contains("settings.json."))
        XCTAssertTrue(dest.pathExtension == "bak" || dest.lastPathComponent.hasSuffix(".bak"))
    }

    func testClaudeSettingsWriterToggleOnOffPreservesOtherKeys() throws {
        let file = tempDir.appendingPathComponent("claude-settings.json")
        let original = """
        {
          "permissions": { "allow": ["Bash"] },
          "model": "opus",
          "hooks": { "PreToolUse": [] },
          "effortLevel": "high"
        }
        """
        try original.write(to: file, atomically: true, encoding: .utf8)

        let writer = ClaudeSettingsWriter(fileURL: file, appSupportDir: tempDir)
        try writer.enableProxy(baseURL: "http://127.0.0.1:4000", masterKey: "sk-test")

        let enabled = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertEqual(enabled["model"] as? String, "opus")
        let env = enabled["env"] as! [String: Any]
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"] as? String, "http://127.0.0.1:4000")
        XCTAssertEqual(env["ANTHROPIC_AUTH_TOKEN"] as? String, "sk-test")

        try writer.disableProxy()
        let disabled = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        XCTAssertNil(disabled["env"])
        XCTAssertEqual(disabled["model"] as? String, "opus")
        XCTAssertNotNil(disabled["permissions"])
        XCTAssertNotNil(disabled["hooks"])
    }

    func testClaudeSettingsWriterLeavesOtherEnvKeys() throws {
        let file = tempDir.appendingPathComponent("claude-settings.json")
        try """
        {
          "env": {
            "FOO": "bar",
            "ANTHROPIC_BASE_URL": "http://old",
            "ANTHROPIC_AUTH_TOKEN": "old"
          }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let writer = ClaudeSettingsWriter(fileURL: file, appSupportDir: tempDir)
        try writer.disableProxy()
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let env = root["env"] as! [String: Any]
        XCTAssertEqual(env["FOO"] as? String, "bar")
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
    }

    func testVSCodeSettingsWriterInsertWhenAbsent() throws {
        let file = tempDir.appendingPathComponent("vscode-settings.json")
        try """
        {
            "editor.fontSize": 14,
            "claudeCode.selectedModel": "default"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let writer = VSCodeSettingsWriter(fileURL: file, appSupportDir: tempDir)
        try writer.enableProxy(baseURL: "http://127.0.0.1:4000", masterKey: "mk")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("claudeCode.environmentVariables"))
        XCTAssertTrue(text.contains("ANTHROPIC_BASE_URL"))
        XCTAssertTrue(text.contains("editor.fontSize"))
        XCTAssertTrue(text.contains("claudeCode.selectedModel"))
    }

    func testVSCodeSettingsWriterPreservesAdjacentComment() throws {
        let file = tempDir.appendingPathComponent("vscode-settings.json")
        try """
        {
            // keep this comment
            "editor.fontSize": 14,
            "claudeCode.environmentVariables": [
                {
                    "name": "ANTHROPIC_BASE_URL",
                    "value": "http://old"
                },
                {
                    "name": "ANTHROPIC_AUTH_TOKEN",
                    "value": "old"
                }
            ],
            "files.autoSave": "afterDelay"
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let writer = VSCodeSettingsWriter(fileURL: file, appSupportDir: tempDir)
        try writer.enableProxy(baseURL: "http://127.0.0.1:4000", masterKey: "mk")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("// keep this comment"))
        XCTAssertTrue(text.contains("http://127.0.0.1:4000"))
        XCTAssertTrue(text.contains("files.autoSave"))
        XCTAssertFalse(text.contains("http://old"))
    }

    func testVSCodeSettingsWriterRemovesOnlyRelayEntries() throws {
        let file = tempDir.appendingPathComponent("vscode-settings.json")
        try """
        {
            "claudeCode.environmentVariables": [
                {
                    "name": "CUSTOM_VAR",
                    "value": "keep-me"
                },
                {
                    "name": "ANTHROPIC_BASE_URL",
                    "value": "http://127.0.0.1:4000"
                },
                {
                    "name": "ANTHROPIC_AUTH_TOKEN",
                    "value": "mk"
                }
            ]
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let writer = VSCodeSettingsWriter(fileURL: file, appSupportDir: tempDir)
        try writer.disableProxy()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("CUSTOM_VAR"))
        XCTAssertTrue(text.contains("keep-me"))
        XCTAssertFalse(text.contains("ANTHROPIC_BASE_URL"))
        XCTAssertFalse(text.contains("ANTHROPIC_AUTH_TOKEN"))
    }

    func testLiteLLMConfigWriterRendersExpectedYAML() throws {
        let writer = LiteLLMConfigWriter(directory: tempDir)
        let config = LiteLLMConfig(
            modelString: "deepseek/deepseek-v4-pro",
            apiKeyEnvVar: Provider.deepSeek.envVar
        )
        let yaml = writer.render(config)
        XCTAssertTrue(yaml.contains("model_name: \"*\""))
        XCTAssertTrue(yaml.contains("model: deepseek/deepseek-v4-pro"))
        XCTAssertTrue(yaml.contains("api_key: os.environ/DEEPSEEK_API_KEY"))
        XCTAssertTrue(yaml.contains("master_key: os.environ/LITELLM_MASTER_KEY"))
        XCTAssertTrue(yaml.contains("callbacks: [\"prometheus\"]"))
        try writer.write(config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.configURL.path))
    }

    func testLiteLLMConfigWriterRendersAnthropicYAML() throws {
        let writer = LiteLLMConfigWriter(directory: tempDir)
        let config = LiteLLMConfig(
            modelString: "anthropic/claude-sonnet-5-20250929",
            apiKeyEnvVar: Provider.anthropic.envVar
        )
        let yaml = writer.render(config)
        XCTAssertTrue(yaml.contains("model: anthropic/claude-sonnet-5-20250929"))
        XCTAssertTrue(yaml.contains("api_key: os.environ/ANTHROPIC_API_KEY"))
    }

    func testLiteLLMConfigWriterRendersGroqCallbackWhenConfigured() throws {
        let writer = LiteLLMConfigWriter(directory: tempDir)
        let config = LiteLLMConfig(
            modelString: "deepseek/deepseek-v4-pro",
            apiKeyEnvVar: Provider.deepSeek.envVar,
            groqConfigured: true
        )
        let yaml = writer.render(config)
        XCTAssertTrue(yaml.contains("callbacks: [\"prometheus\", \"groq_vision_callback.proxy_handler_instance\"]"))
    }

    func testRoutingStateStoreRoundTrip() throws {
        let url = tempDir.appendingPathComponent("routing-state.json")
        let store = RoutingStateStore(fileURL: url)
        XCTAssertEqual(store.load().mode, .claude)
        try store.save(RoutingState(mode: .deepSeek))
        XCTAssertEqual(store.load().mode, .deepSeek)
    }
}
