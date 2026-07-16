import Foundation
import Security

public struct ToggleResult: Equatable, Sendable {
    public let mode: RoutingMode
    public let caveatMessage: String
    public let provider: Provider?

    public static let restartCaveat =
        "Already-open `claude` terminal sessions and VS Code windows won't see this change until restarted."
}

public enum ToggleError: Error, CustomStringConvertible, LocalizedError {
    case missingAPIKey(Provider)
    case venv(VenvInstallError)
    case proxy(String)
    case settings(String)
    case other(String)

    public var description: String {
        switch self {
        case .missingAPIKey(let provider):
            return "Set your \(provider.displayName) API key before switching."
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

    public func hasAPIKey(for provider: Provider) -> Bool {
        !(keychain.read(provider.keychainKey) ?? "").isEmpty
    }

    public func apiKey(for provider: Provider) -> String? {
        keychain.read(provider.keychainKey)
    }

    public func setAPIKey(_ value: String, for provider: Provider) {
        if value.isEmpty {
            keychain.delete(provider.keychainKey)
        } else {
            _ = keychain.write(value, for: provider.keychainKey)
        }
    }

    // MARK: - Groq vision

    /// Groq isn't a routing `Provider` — it's a global image→text preprocessor that
    /// rides in front of whichever provider is active, so it gets its own accessors
    /// rather than going through `hasAPIKey(for:)`/`setAPIKey(_:for:)`.
    public func hasGroqAPIKey() -> Bool {
        !(keychain.read(.groqAPIKey) ?? "").isEmpty
    }

    public func getGroqAPIKey() -> String? {
        keychain.read(.groqAPIKey)
    }

    public func setGroqAPIKey(_ value: String) {
        if value.isEmpty {
            keychain.delete(.groqAPIKey)
        } else {
            _ = keychain.write(value, for: .groqAPIKey)
        }
    }

    public func groqModelString() -> String {
        preferencesStore.load().groqModelString
    }

    /// Ensure the Groq vision callback Python file is installed in the app support
    /// directory so LiteLLM can import it. Caller provides the bundled resource URL.
    public func installGroqCallback(from sourceURL: URL) throws {
        try venvInstaller.installCallback(from: sourceURL)
    }

    /// Builds the proxy subprocess environment, adding Groq vision vars (+ PYTHONPATH so
    /// the callback module is importable) when a Groq key is configured.
    private func proxyEnvironment(apiKey: String, masterKey: String, provider: Provider) -> [String: String] {
        var env: [String: String] = [
            provider.envVar: apiKey,
            AppSupport.masterKeyEnvVar: masterKey,
        ]
        if hasGroqAPIKey(), let groqKey = keychain.read(.groqAPIKey) {
            env[AppSupport.groqAPIKeyEnvVar] = groqKey
            env[AppSupport.groqVisionModelEnvVar] = groqModelString()
            env["PYTHONPATH"] = venvInstaller.appSupportDir.path
        }
        return env
    }

    public func switchTo(provider: Provider) async throws -> ToggleResult {
        guard let apiKey = keychain.read(provider.keychainKey), !apiKey.isEmpty else {
            throw ToggleError.missingAPIKey(provider)
        }

        do {
            _ = try await venvInstaller.ensureReady()
        } catch let error as VenvInstallError {
            throw ToggleError.venv(error)
        } catch {
            throw ToggleError.other(error.localizedDescription)
        }

        let masterKey = ensureMasterKey()
        var prefs = preferencesStore.load()
        prefs.activeProvider = provider
        try preferencesStore.save(prefs)
        let model = prefs.activeModel()
        proxyManager.updatePort(prefs.proxyPort)

        do {
            try configWriter.write(
                LiteLLMConfig(modelString: model, apiKeyEnvVar: provider.envVar, port: prefs.proxyPort, groqConfigured: hasGroqAPIKey())
            )
            try claudeWriter.enableProxy(baseURL: AppSupport.baseURL(port: prefs.proxyPort), masterKey: masterKey)
            try vscodeWriter.enableProxy(baseURL: AppSupport.baseURL(port: prefs.proxyPort), masterKey: masterKey)
        } catch {
            throw ToggleError.settings(error.localizedDescription)
        }

        do {
            try await proxyManager.start(
                environment: proxyEnvironment(apiKey: apiKey, masterKey: masterKey, provider: provider)
            )
        } catch {
            try? claudeWriter.disableProxy()
            try? vscodeWriter.disableProxy()
            throw ToggleError.proxy(error.localizedDescription)
        }

        try routingStore.save(RoutingState(mode: .deepSeek))
        return ToggleResult(mode: .deepSeek, caveatMessage: ToggleResult.restartCaveat, provider: provider)
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
        return ToggleResult(mode: .claude, caveatMessage: ToggleResult.restartCaveat, provider: nil)
    }

    /// Revert routing to Claude without throwing — safe to call during app termination.
    public func revertToClaude() throws {
        proxyManager.stop()
        try? claudeWriter.disableProxy()
        try? vscodeWriter.disableProxy()
        try routingStore.save(RoutingState(mode: .claude))
    }

    public func startProxyManually(for provider: Provider) async throws {
        guard let apiKey = keychain.read(provider.keychainKey), !apiKey.isEmpty else {
            throw ToggleError.missingAPIKey(provider)
        }
        _ = try await venvInstaller.ensureReady()
        let masterKey = ensureMasterKey()
        let prefs = preferencesStore.load()
        proxyManager.updatePort(prefs.proxyPort)
        try configWriter.write(
            LiteLLMConfig(modelString: prefs.activeModel(), apiKeyEnvVar: provider.envVar, port: prefs.proxyPort, groqConfigured: hasGroqAPIKey())
        )
        try await proxyManager.start(
            environment: proxyEnvironment(apiKey: apiKey, masterKey: masterKey, provider: provider)
        )
    }

    public func stopProxyManually() {
        proxyManager.stop()
    }

    /// Saves the chosen model for a provider. Does NOT change the active provider.
    /// If that provider is currently active and the proxy is running, restarts it
    /// so the change takes effect immediately.
    public func setModel(_ model: String, for provider: Provider) async throws {
        var prefs = preferencesStore.load()
        prefs.providerModels[provider] = model
        try preferencesStore.save(prefs)
        guard prefs.activeProvider == provider else { return }
        try await restartRunningProxyIfNeeded(provider: provider, model: model, port: prefs.proxyPort)
    }

    /// Saves a provider's model (from its settings panel). Same semantics as
    /// `setModel(_:for:)` — activation only ever happens via `switchTo(provider:)`.
    public func updateProviderSettings(provider: Provider, model: String) async throws {
        try await setModel(model, for: provider)
    }

    /// Saves the proxy port and, if the proxy is running, restarts it on the new
    /// port with the active provider's model.
    public func updatePort(_ port: Int) async throws {
        var prefs = preferencesStore.load()
        prefs.proxyPort = port
        try preferencesStore.save(prefs)
        try await restartRunningProxyIfNeeded(provider: prefs.activeProvider, model: prefs.activeModel(), port: port)
    }

    /// Rewrites the config for the given provider/model/port and restarts the proxy —
    /// but only if it's already running. A no-op if the proxy is stopped.
    private func restartRunningProxyIfNeeded(provider: Provider, model: String, port: Int) async throws {
        guard case .running = proxyManager.status else { return }
        guard let apiKey = keychain.read(provider.keychainKey), !apiKey.isEmpty else { return }
        let masterKey = ensureMasterKey()
        proxyManager.updatePort(port)
        try configWriter.write(
            LiteLLMConfig(modelString: model, apiKeyEnvVar: provider.envVar, port: port, groqConfigured: hasGroqAPIKey())
        )
        proxyManager.stop()
        try await proxyManager.start(
            environment: proxyEnvironment(apiKey: apiKey, masterKey: masterKey, provider: provider)
        )
        try claudeWriter.enableProxy(baseURL: AppSupport.baseURL(port: port), masterKey: masterKey)
        try vscodeWriter.enableProxy(baseURL: AppSupport.baseURL(port: port), masterKey: masterKey)
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
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
