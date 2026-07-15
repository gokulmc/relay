import Foundation
import XCTest
@testable import RelayKit

final class ToggleServiceTests: XCTestCase {
    private var tempDir: URL!
    private var keychain: KeychainStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        keychain = KeychainStore(serviceSuffix: "toggle-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        keychain.delete(.deepSeekAPIKey)
        keychain.delete(.liteLLMMasterKey)
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSwitchToDeepSeekFailsWithoutAPIKey() async {
        let service = await makeService()
        do {
            _ = try await service.switchToDeepSeek()
            XCTFail("expected missingDeepSeekAPIKey")
        } catch let error as ToggleError {
            guard case .missingDeepSeekAPIKey = error else {
                XCTFail("unexpected \(error)")
                return
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(service.currentMode(), .claude)
    }

    func testSwitchToDeepSeekThenClaudeRoundTrip() async throws {
        guard keychain.write("sk-test-deepseek", for: .deepSeekAPIKey) else {
            throw XCTSkip("Keychain write unavailable in this environment")
        }

        try seedFakeLiteLLM()
        try seedSettingsFiles()

        let service = await makeService(healthAlwaysOK: true)

        let on = try await service.switchToDeepSeek()
        XCTAssertEqual(on.mode, .deepSeek)
        XCTAssertEqual(service.currentMode(), .deepSeek)
        XCTAssertEqual(service.proxy.status, .running)
        XCTAssertTrue(on.caveatMessage.contains("restarted"))

        let claudeSettings = try String(
            contentsOf: tempDir.appendingPathComponent("claude-settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(claudeSettings.contains("ANTHROPIC_BASE_URL"))
        XCTAssertTrue(claudeSettings.contains("127.0.0.1:4000"))

        let vscodeSettings = try String(
            contentsOf: tempDir.appendingPathComponent("vscode-settings.json"),
            encoding: .utf8
        )
        XCTAssertTrue(vscodeSettings.contains("claudeCode.environmentVariables"))

        let off = try await service.switchToClaude()
        XCTAssertEqual(off.mode, .claude)
        XCTAssertEqual(service.currentMode(), .claude)
        XCTAssertEqual(service.proxy.status, .stopped)

        let claudeAfter = try String(
            contentsOf: tempDir.appendingPathComponent("claude-settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(claudeAfter.contains("ANTHROPIC_BASE_URL"))
    }

    func testProxyStartFailureRollsBackSettings() async throws {
        guard keychain.write("sk-test-deepseek", for: .deepSeekAPIKey) else {
            throw XCTSkip("Keychain write unavailable in this environment")
        }

        // Binary present + config will be written, but health never succeeds → start fails.
        try seedFakeLiteLLM(scriptBody: "#!/bin/sh\nexit 1\n")
        try seedSettingsFiles()

        let service = await makeService(healthAlwaysOK: false)
        do {
            _ = try await service.switchToDeepSeek()
            XCTFail("expected proxy failure")
        } catch let error as ToggleError {
            guard case .proxy = error else {
                XCTFail("unexpected \(error)")
                return
            }
        } catch {
            XCTFail("unexpected \(error)")
        }

        XCTAssertEqual(service.currentMode(), .claude)
        let claudeSettings = try String(
            contentsOf: tempDir.appendingPathComponent("claude-settings.json"),
            encoding: .utf8
        )
        XCTAssertFalse(claudeSettings.contains("ANTHROPIC_BASE_URL"))
    }

    // MARK: - Helpers

    private func makeService(healthAlwaysOK: Bool = true) async -> ToggleService {
        let runner = FakeProcessRunner()
        // Venv short-circuit: --version succeeds once litellm exists.
        await runner.enqueueSuccess(stdout: "litellm 1.0\n")

        let litellmPath = tempDir.appendingPathComponent("venv/bin/litellm").path
        let logs = ProxyLogStore()
        let proxy = ProxyProcessManager(
            appSupportDir: tempDir,
            logStore: logs,
            healthCheck: { _ in healthAlwaysOK },
            pathForPID: { _ in litellmPath },
            healthTimeout: healthAlwaysOK ? 10 : 0.1
        )

        return ToggleService(
            keychain: keychain,
            routingStore: RoutingStateStore(fileURL: tempDir.appendingPathComponent("state.json")),
            preferencesStore: RelayPreferencesStore(fileURL: tempDir.appendingPathComponent("preferences.json")),
            venvInstaller: VenvInstaller(appSupportDir: tempDir, runner: runner),
            configWriter: LiteLLMConfigWriter(directory: tempDir),
            claudeWriter: ClaudeSettingsWriter(
                fileURL: tempDir.appendingPathComponent("claude-settings.json"),
                appSupportDir: tempDir
            ),
            vscodeWriter: VSCodeSettingsWriter(
                fileURL: tempDir.appendingPathComponent("vscode-settings.json"),
                appSupportDir: tempDir
            ),
            proxyManager: proxy
        )
    }

    private func seedFakeLiteLLM(scriptBody: String = "#!/bin/sh\nwhile true; do sleep 60; done\n") throws {
        let bin = tempDir.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let litellm = bin.appendingPathComponent("litellm")
        try scriptBody.write(to: litellm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: litellm.path)
    }

    private func seedSettingsFiles() throws {
        try #"{ "model": "opus", "permissions": {} }"#
            .write(to: tempDir.appendingPathComponent("claude-settings.json"), atomically: true, encoding: .utf8)
        try """
            {
                "editor.fontSize": 14
            }
            """.write(to: tempDir.appendingPathComponent("vscode-settings.json"), atomically: true, encoding: .utf8)
    }
}
