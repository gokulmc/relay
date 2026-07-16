import Foundation

public struct UsageTotals: Codable, Equatable, Sendable {
    public var totalSpendUSD: Double
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    /// Lifetime spend attributed to each provider. Only providers without a live
    /// balance API rely on this; DeepSeek's real balance comes from its API.
    public var perProviderSpendUSD: [Provider: Double]

    public init(
        totalSpendUSD: Double = 0,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        perProviderSpendUSD: [Provider: Double] = [:]
    ) {
        self.totalSpendUSD = totalSpendUSD
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.perProviderSpendUSD = perProviderSpendUSD
    }

    private enum CodingKeys: String, CodingKey {
        case totalSpendUSD, totalInputTokens, totalOutputTokens, perProviderSpendUSD
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalSpendUSD = try container.decodeIfPresent(Double.self, forKey: .totalSpendUSD) ?? 0
        totalInputTokens = try container.decodeIfPresent(Int.self, forKey: .totalInputTokens) ?? 0
        totalOutputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens) ?? 0
        perProviderSpendUSD = try container.decodeIfPresent([Provider: Double].self, forKey: .perProviderSpendUSD) ?? [:]
    }
}

/// Persists lifetime usage totals across proxy restarts and app launches.
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
    /// Call whenever the proxy stops or restarts, since its in-memory counters are
    /// about to reset. `provider` attributes the spend for per-provider tracking.
    @discardableResult
    public func commitSession(_ sessionUsage: UsageSample, provider: Provider? = nil) throws -> UsageTotals {
        var totals = load()
        totals.totalSpendUSD += sessionUsage.spendUSD
        totals.totalInputTokens += sessionUsage.inputTokens
        totals.totalOutputTokens += sessionUsage.outputTokens
        if let provider, sessionUsage.spendUSD > 0 {
            totals.perProviderSpendUSD[provider, default: 0] += sessionUsage.spendUSD
        }
        try save(totals)
        return totals
    }
}
