import Foundation

public struct LiteLLMConfig: Equatable, Sendable {
    public var deepSeekModelString: String
    public var deepSeekAPIKeyEnvVar: String
    public var masterKeyEnvVar: String
    public var port: Int

    public init(
        deepSeekModelString: String,
        deepSeekAPIKeyEnvVar: String = AppSupport.deepSeekAPIKeyEnvVar,
        masterKeyEnvVar: String = AppSupport.masterKeyEnvVar,
        port: Int = AppSupport.defaultPort
    ) {
        self.deepSeekModelString = deepSeekModelString
        self.deepSeekAPIKeyEnvVar = deepSeekAPIKeyEnvVar
        self.masterKeyEnvVar = masterKeyEnvVar
        self.port = port
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
        """
        model_list:
          - model_name: "*"
            litellm_params:
              model: \(config.deepSeekModelString)
              api_key: os.environ/\(config.deepSeekAPIKeyEnvVar)

        general_settings:
          master_key: os.environ/\(config.masterKeyEnvVar)

        litellm_settings:
          drop_params: true

        """
    }

    public func write(_ config: LiteLLMConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(render(config).utf8)
        try data.write(to: configURL, options: .atomic)
    }
}
