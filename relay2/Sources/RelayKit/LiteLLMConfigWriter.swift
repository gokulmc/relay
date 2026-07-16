import Foundation

public struct LiteLLMConfig: Equatable, Sendable {
    /// Provider-qualified model string, e.g. "anthropic/claude-sonnet-5-20250929"
    public var modelString: String
    /// Env var name that holds the API key, e.g. "ANTHROPIC_API_KEY"
    public var apiKeyEnvVar: String
    public var masterKeyEnvVar: String
    public var port: Int
    /// Whether the Groq vision image→text preprocessor callback should be enabled.
    public var groqConfigured: Bool

    public init(
        modelString: String,
        apiKeyEnvVar: String,
        masterKeyEnvVar: String = AppSupport.masterKeyEnvVar,
        port: Int = AppSupport.defaultPort,
        groqConfigured: Bool = false
    ) {
        self.modelString = modelString
        self.apiKeyEnvVar = apiKeyEnvVar
        self.masterKeyEnvVar = masterKeyEnvVar
        self.port = port
        self.groqConfigured = groqConfigured
    }
}

public struct LiteLLMConfigWriter {
    private let directory: URL

    public init(directory: URL = AppSupport.defaultDirectory()) {
        self.directory = directory
    }

    public var configURL: URL {
        directory.appendingPathComponent("litellm-config.yaml")
    }

    public func render(_ config: LiteLLMConfig) -> String {
        // The Groq vision callback (image → text) rides alongside prometheus in the
        // callbacks list. `groq_vision_callback` must be importable — the app installs
        // it next to this config and puts that dir on PYTHONPATH when starting the proxy.
        let callbacks = config.groqConfigured
            ? "[\"prometheus\", \"\(AppSupport.groqVisionCallbackModule).proxy_handler_instance\"]"
            : "[\"prometheus\"]"
        return """
        model_list:
          - model_name: "*"
            litellm_params:
              model: \(config.modelString)
              api_key: os.environ/\(config.apiKeyEnvVar)

        general_settings:
          master_key: os.environ/\(config.masterKeyEnvVar)

        litellm_settings:
          drop_params: true
          callbacks: \(callbacks)
          require_auth_for_metrics_endpoint: false

        """
    }

    public func write(_ config: LiteLLMConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(render(config).utf8)
        try data.write(to: configURL, options: .atomic)
    }
}
