import Foundation

public struct UsageTotals: Codable, Equatable, Sendable {
    public var totalSpendUSD: Double
    public var totalInputTokens: Int
    public var totalOutputTokens: Int

    public init(totalSpendUSD: Double = 0, totalInputTokens: Int = 0, totalOutputTokens: Int = 0) {
        self.totalSpendUSD = totalSpendUSD
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
    }
}

/// Persists lifetime DeepSeek usage totals across proxy restarts and app launches.
/// LiteLLM's own Prometheus counters live in-process and reset to zero every time the
/// proxy restarts, so this file is the only durable record. Written when the proxy
/// stops (not on every scrape) to avoid disk churn during normal polling.
public struct UsageStore {
    private let fileURL: URL

    public init(fileURL: URL = UsageStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        AppSupport.defaultDirectory().appendingPathComponent("usage.json")
    }

    public func load() -> UsageTotals {
        guard let data = try? Data(contentsOf: fileURL) else { return UsageTotals() }
        return (try? JSONDecoder().decode(UsageTotals.self, from: data)) ?? UsageTotals()
    }

    public func save(_ totals: UsageTotals) throws {
        try AppSupport.ensureDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(totals)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Folds a finished session's usage into the persisted lifetime totals and saves.
    /// Call when the proxy stops, since its in-memory counters are about to reset.
    @discardableResult
    public func commitSession(_ sessionUsage: UsageSample) throws -> UsageTotals {
        var totals = load()
        totals.totalSpendUSD += sessionUsage.spendUSD
        totals.totalInputTokens += sessionUsage.inputTokens
        totals.totalOutputTokens += sessionUsage.outputTokens
        try save(totals)
        return totals
    }
}
