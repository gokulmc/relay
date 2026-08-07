import XCTest
@testable import RelayKit

final class MenuTextTests: XCTestCase {
    func testShortInputIsUnchanged() {
        XCTAssertEqual(MenuText.menuErrorSummary("missing API key"), "missing API key")
    }

    func testMultiLineInputCollapsesToOneLine() {
        let traceback = """
        Traceback (most recent call last):
          File "litellm/proxy.py", line 42, in start
            raise ValueError("bad config")
        ValueError: bad config
        """
        let summary = MenuText.menuErrorSummary(traceback, cap: 1000)
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertTrue(summary.contains("Traceback"))
        XCTAssertTrue(summary.contains("ValueError: bad config"))
    }

    func testLongInputIsTruncatedWithEllipsisAndStaysWithinCap() {
        let raw = String(repeating: "x", count: 500)
        let summary = MenuText.menuErrorSummary(raw, cap: 60)
        XCTAssertTrue(summary.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(summary.count, 61) // cap + 1 for the ellipsis character
    }

    func testEmptyLinesBetweenContentAreDropped() {
        let raw = "first line\n\n\nsecond line"
        let summary = MenuText.menuErrorSummary(raw, cap: 1000)
        XCTAssertEqual(summary, "first line second line")
    }

    func testDefaultCapIsRespected() {
        let raw = String(repeating: "y", count: 500)
        let summary = MenuText.menuErrorSummary(raw)
        XCTAssertLessThanOrEqual(summary.count, MenuText.defaultSummaryCap + 1)
    }
}
