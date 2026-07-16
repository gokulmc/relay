import Foundation

public struct UsageSample: Equatable, Sendable {
    public var spendUSD: Double
    public var inputTokens: Int
    public var outputTokens: Int

    public init(spendUSD: Double = 0, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.spendUSD = spendUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let zero = UsageSample()
}

public enum UsageScraperError: Error, CustomStringConvertible, Equatable {
    case badResponse(Int)
    case decoding

    public var description: String {
        switch self {
        case .badResponse(let code): return "Metrics endpoint returned status \(code)"
        case .decoding: return "Metrics endpoint returned non-UTF8 data"
        }
    }
}

/// Scrapes LiteLLM's Prometheus `/metrics/` text endpoint for cumulative spend + token
/// counters. Deliberately not a full Prometheus parser — litellm resets these counters
/// to zero on every process start, so we just sum the value on every line for the three
/// counters we care about (one line per label combination) and ignore labels entirely.
public struct UsageScraper: Sendable {
    private let metricsURL: URL
    private let session: URLSession

    public init(baseURL: String = AppSupport.baseURL(), session: URLSession = .shared) {
        self.metricsURL = URL(string: "\(baseURL)/metrics/")!
        self.session = session
    }

    public func scrape() async throws -> UsageSample {
        let (data, response) = try await session.data(from: metricsURL)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw UsageScraperError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw UsageScraperError.decoding
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> UsageSample {
        UsageSample(
            spendUSD: sum(metric: "litellm_spend_metric_total", in: text),
            inputTokens: Int(sum(metric: "litellm_input_tokens_metric_total", in: text)),
            outputTokens: Int(sum(metric: "litellm_output_tokens_metric_total", in: text))
        )
    }

    /// Sums the trailing numeric value of every non-comment line starting with
    /// `metric{...}` or `metric ` (Prometheus text exposition format).
    private static func sum(metric: String, in text: String) -> Double {
        var total = 0.0
        for line in text.split(separator: "\n") {
            guard line.hasPrefix(metric + "{") || line.hasPrefix(metric + " ") else { continue }
            guard let valueToken = line.split(separator: " ").last, let value = Double(valueToken) else { continue }
            total += value
        }
        return total
    }
}
