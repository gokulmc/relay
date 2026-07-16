import Foundation
import XCTest
@testable import RelayKit

final class UsageScraperParsingTests: XCTestCase {
    func testParseSumsSpendAndTokensAcrossLabelLines() {
        let text = """
        # HELP litellm_spend_metric_total Total spend on LLM requests
        # TYPE litellm_spend_metric_total counter
        litellm_spend_metric_total{model="deepseek-v4-pro"} 0.42
        litellm_spend_metric_total{model="deepseek-v4-flash"} 0.08
        # HELP litellm_input_tokens_metric_total Total number of input tokens
        # TYPE litellm_input_tokens_metric_total counter
        litellm_input_tokens_metric_total{model="deepseek-v4-pro"} 1000.0
        # HELP litellm_output_tokens_metric_total Total number of output tokens
        # TYPE litellm_output_tokens_metric_total counter
        litellm_output_tokens_metric_total{model="deepseek-v4-pro"} 250.0
        """
        let sample = UsageScraper.parse(text)
        XCTAssertEqual(sample.spendUSD, 0.50, accuracy: 0.0001)
        XCTAssertEqual(sample.inputTokens, 1000)
        XCTAssertEqual(sample.outputTokens, 250)
    }

    func testParseWithNoDataLinesReturnsZero() {
        let text = """
        # HELP litellm_spend_metric_total Total spend on LLM requests
        # TYPE litellm_spend_metric_total counter
        """
        let sample = UsageScraper.parse(text)
        XCTAssertEqual(sample, .zero)
    }

    func testParseIgnoresUnrelatedMetrics() {
        let text = """
        python_gc_objects_collected_total{generation="0"} 3754.0
        litellm_proxy_total_requests_metric_total{} 5.0
        """
        let sample = UsageScraper.parse(text)
        XCTAssertEqual(sample, .zero)
    }
}

final class UsageStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadWithNoFileReturnsZeroTotals() {
        let store = UsageStore(fileURL: tempDir.appendingPathComponent("usage.json"))
        XCTAssertEqual(store.load(), UsageTotals())
    }

    func testCommitSessionAccumulatesAcrossMultipleCommits() throws {
        let store = UsageStore(fileURL: tempDir.appendingPathComponent("usage.json"))

        try store.commitSession(UsageSample(spendUSD: 0.50, inputTokens: 1000, outputTokens: 250))
        let afterFirst = store.load()
        XCTAssertEqual(afterFirst.totalSpendUSD, 0.50, accuracy: 0.0001)
        XCTAssertEqual(afterFirst.totalInputTokens, 1000)
        XCTAssertEqual(afterFirst.totalOutputTokens, 250)

        try store.commitSession(UsageSample(spendUSD: 0.10, inputTokens: 200, outputTokens: 50))
        let afterSecond = store.load()
        XCTAssertEqual(afterSecond.totalSpendUSD, 0.60, accuracy: 0.0001)
        XCTAssertEqual(afterSecond.totalInputTokens, 1200)
        XCTAssertEqual(afterSecond.totalOutputTokens, 300)
    }
}
