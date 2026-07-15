import Foundation

/// Which credential Claude Code is currently routed through.
public enum RoutingMode: String, Codable, Equatable, Sendable {
    case claude
    case deepSeek
}

public struct RoutingState: Codable, Equatable {
    public let mode: RoutingMode
    public let updatedAt: Date

    public init(mode: RoutingMode, updatedAt: Date = Date()) {
        self.mode = mode
        self.updatedAt = updatedAt
    }
}

/// Persists `RoutingState` as JSON at `~/Library/Application Support/Relay/routing-state.json`
/// (path is injectable for tests). If the file is missing or fails to decode, `load()` returns
/// a default state of `.claude` rather than throwing — there's no meaningful "error" state for
/// "we don't know yet," and `.claude` is always the safe default (it's the subscription login,
/// never destructive to assume).
public struct RoutingStateStore {
    private let fileURL: URL

    public init(fileURL: URL = RoutingStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Relay", isDirectory: true)
            .appendingPathComponent("routing-state.json")
    }

    public func load() -> RoutingState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return RoutingState(mode: .claude)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(RoutingState.self, from: data) else {
            return RoutingState(mode: .claude)
        }
        return state
    }

    public func save(_ state: RoutingState) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
