import Foundation
import Security

public struct ToggleResult: Equatable, Sendable {
    public let mode: RoutingMode
    public let caveatMessage: String

    public static let restartCaveat =
        "Already-open `claude` terminal sessions and VS Code windows won't see this change until restarted."
}

public enum ToggleError: Error, CustomStringConvertible, LocalizedError {
    case missingDeepSeekAPIKey
    case venv(VenvInstallError)
    case proxy(String)
    case settings(String)
    case other(String)

    public var description: String {
        switch self {
        case .missingDeepSeekAPIKey:
            return "Set your DeepSeek API key before switching."
        case .venv(let error):
            return error.description
        case .proxy(let message), .settings(let message), .other(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// Coordinates routing toggles: settings writers + proxy lifecycle + persisted state.
public final class ToggleService: @unchecked Sendable {
    private let keychain: KeychainStore
    private let routingStore: RoutingStateStore
    private let preferencesStore: RelayPreferencesStore
    private let venvInstaller: VenvInstaller
    private let configWriter: LiteLLMConfigWriter
    private let claudeWriter: ClaudeSettingsWriter
    private let vscodeWriter: VSCodeSettingsWriter
    private let proxyManager: ProxyProcessManager
    private let lock = NSLock()

    public init(
        keychain: KeychainStore = KeychainStore(),
        routingStore: RoutingStateStore = RoutingStateStore(),
        preferencesStore: RelayPreferencesStore = RelayPreferencesStore(),
        venvInstaller: VenvInstaller = VenvInstaller(),
        configWriter: LiteLLMConfigWriter = LiteLLMConfigWriter(),
        claudeWriter: ClaudeSettingsWriter = ClaudeSettingsWriter(),
        vscodeWriter: VSCodeSettingsWriter = VSCodeSettingsWriter(),
        proxyManager: ProxyProcessManager
    ) {
        self.keychain = keychain
        self.routingStore = routingStore
        self.preferencesStore = preferencesStore
        self.venvInstaller = venvInstaller
        self.configWriter = configWriter
        self.claudeWriter = claudeWriter
        self.vscodeWriter = vscodeWriter
        self.proxyManager = proxyManager
    }

    public convenience init() {
        let logs = ProxyLogStore()
        let proxy = ProxyProcessManager(logStore: logs)
        self.init(proxyManager: proxy)
    }

    public var proxy: ProxyProcessManager { proxyManager }
    public var logs: ProxyLogStore { proxyManager.logs }

    public func currentMode() -> RoutingMode {
        routingStore.load().mode
    }

    public func preferences() -> RelayPreferences {
        preferencesStore.load()
    }

    public func savePreferences(_ preferences: RelayPreferences) throws {
        try preferencesStore.save(preferences)
    }

    public func hasDeepSeekAPIKey() -> Bool {
        !(keychain.read(.deepSeekAPIKey) ?? "").isEmpty
    }

    public func setDeepSeekAPIKey(_ value: String) {
        if value.isEmpty {
            keychain.delete(.deepSeekAPIKey)
        } else {
            _ = keychain.write(value, for: .deepSeekAPIKey)
        }
    }

    public func switchToDeepSeek() async throws -> ToggleResult {
        guard let apiKey = keychain.read(.deepSeekAPIKey), !apiKey.isEmpty else {
            throw ToggleError.missingDeepSeekAPIKey
        }

        do {
            _ = try await venvInstaller.ensureReady()
        } catch let error as VenvInstallError {
            throw ToggleError.venv(error)
        } catch {
            throw ToggleError.other(error.localizedDescription)
        }

        let masterKey = ensureMasterKey()
        let prefs = preferencesStore.load()

        do {
            try configWriter.write(
                LiteLLMConfig(deepSeekModelString: prefs.deepSeekModelString)
            )
            try claudeWriter.enableProxy(baseURL: AppSupport.baseURL, masterKey: masterKey)
            try vscodeWriter.enableProxy(baseURL: AppSupport.baseURL, masterKey: masterKey)
        } catch {
            throw ToggleError.settings(error.localizedDescription)
        }

        do {
            try await proxyManager.start(environment: [
                AppSupport.deepSeekAPIKeyEnvVar: apiKey,
                AppSupport.masterKeyEnvVar: masterKey,
            ])
        } catch {
            // Roll back settings so we don't leave Claude pointed at a dead proxy.
            try? claudeWriter.disableProxy()
            try? vscodeWriter.disableProxy()
            throw ToggleError.proxy(error.localizedDescription)
        }

        try routingStore.save(RoutingState(mode: .deepSeek))
        return ToggleResult(mode: .deepSeek, caveatMessage: ToggleResult.restartCaveat)
    }

    public func switchToClaude() async throws -> ToggleResult {
        proxyManager.stop()

        do {
            try claudeWriter.disableProxy()
            try vscodeWriter.disableProxy()
        } catch {
            throw ToggleError.settings(error.localizedDescription)
        }

        try routingStore.save(RoutingState(mode: .claude))
        return ToggleResult(mode: .claude, caveatMessage: ToggleResult.restartCaveat)
    }

    public func startProxyManually() async throws {
        guard let apiKey = keychain.read(.deepSeekAPIKey), !apiKey.isEmpty else {
            throw ToggleError.missingDeepSeekAPIKey
        }
        _ = try await venvInstaller.ensureReady()
        let masterKey = ensureMasterKey()
        let prefs = preferencesStore.load()
        try configWriter.write(LiteLLMConfig(deepSeekModelString: prefs.deepSeekModelString))
        try await proxyManager.start(environment: [
            AppSupport.deepSeekAPIKeyEnvVar: apiKey,
            AppSupport.masterKeyEnvVar: masterKey,
        ])
    }

    public func stopProxyManually() {
        proxyManager.stop()
    }

    public func repairEnvironment() async throws {
        _ = try await venvInstaller.reinstall()
    }

    public func ensureMasterKey() -> String {
        if let existing = keychain.read(.liteLLMMasterKey), !existing.isEmpty {
            return existing
        }
        let generated = Self.generateMasterKey()
        _ = keychain.write(generated, for: .liteLLMMasterKey)
        return generated
    }

    public func regenerateMasterKey() -> String {
        let generated = Self.generateMasterKey()
        _ = keychain.write(generated, for: .liteLLMMasterKey)
        return generated
    }

    private static func generateMasterKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        // base64url without padding
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
