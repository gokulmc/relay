import Foundation

public enum ClaudeSettingsWriterError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .invalidJSON(let message): return "Claude settings.json is not valid JSON: \(message)"
        case .writeFailed(let message): return "Failed to write Claude settings.json: \(message)"
        }
    }
}

/// Full JSON parse + merge + write of `~/.claude/settings.json`'s `env` block.
public struct ClaudeSettingsWriter {
    public static let baseURLKey = "ANTHROPIC_BASE_URL"
    public static let authTokenKey = "ANTHROPIC_AUTH_TOKEN"

    private let fileURL: URL
    private let backup: SettingsBackup

    public init(
        fileURL: URL = ClaudeSettingsWriter.defaultFileURL(),
        appSupportDir: URL = AppSupport.defaultDirectory()
    ) {
        self.fileURL = fileURL
        self.backup = SettingsBackup(appSupportDir: appSupportDir)
    }

    public static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func enableProxy(baseURL: String, masterKey: String) throws {
        try mutate { root in
            var env = (root["env"] as? [String: Any]) ?? [:]
            env[Self.baseURLKey] = baseURL
            env[Self.authTokenKey] = masterKey
            root["env"] = env
        }
    }

    public func disableProxy() throws {
        try mutate { root in
            guard var env = root["env"] as? [String: Any] else { return }
            env.removeValue(forKey: Self.baseURLKey)
            env.removeValue(forKey: Self.authTokenKey)
            if env.isEmpty {
                root.removeValue(forKey: "env")
            } else {
                root["env"] = env
            }
        }
    }

    private func mutate(_ body: (inout [String: Any]) throws -> Void) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try? backup.backup(sourceURL: fileURL)
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw ClaudeSettingsWriterError.invalidJSON("top-level value is not an object")
            }
            root = dict
        } else {
            root = [:]
        }

        try body(&root)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            )
            if data.last != UInt8(ascii: "\n") {
                data.append(UInt8(ascii: "\n"))
            }
            try data.write(to: fileURL, options: .atomic)
        } catch let error as ClaudeSettingsWriterError {
            throw error
        } catch {
            throw ClaudeSettingsWriterError.writeFailed(error.localizedDescription)
        }
    }
}
