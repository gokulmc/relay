import XCTest
@testable import RelayKit

final class ProxyLogStoreTests: XCTestCase {
    func testAppendAndSnapshot() {
        let store = ProxyLogStore()
        store.append("line1")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, ["line1"])
    }

    func testAppendMultipleLines() {
        let store = ProxyLogStore()
        store.append("line1")
        store.append("line2")
        store.append("line3")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, ["line1", "line2", "line3"])
    }

    func testAppendChunkSplitsOnNewlines() {
        let store = ProxyLogStore()
        store.appendChunk("line1\nline2\nline3")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, ["line1", "line2", "line3"])
    }

    func testAppendChunkDropsEmptyLines() {
        let store = ProxyLogStore()
        store.appendChunk("line1\n\nline2\n\n")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, ["line1", "line2"])
    }

    func testAppendChunkMixedEmptyAndNonEmpty() {
        let store = ProxyLogStore()
        store.appendChunk("a\n\nb\nc\n\n\nd")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, ["a", "b", "c", "d"])
    }

    func testCapacityTrimming() {
        let store = ProxyLogStore(capacity: 5)
        for i in 1...10 {
            store.append("line\(i)")
        }
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertEqual(snapshot, ["line6", "line7", "line8", "line9", "line10"])
    }

    func testCapacityTrimmingWithAppendChunk() {
        let store = ProxyLogStore(capacity: 3)
        store.appendChunk("line1\nline2")
        store.appendChunk("line3\nline4\nline5")
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot, ["line3", "line4", "line5"])
    }

    func testClear() {
        let store = ProxyLogStore()
        store.append("line1")
        store.append("line2")
        store.append("line3")
        store.clear()
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot, [])
    }

    func testJoinedText() {
        let store = ProxyLogStore()
        store.append("line1")
        store.append("line2")
        store.append("line3")
        let joined = store.joinedText
        XCTAssertEqual(joined, "line1\nline2\nline3")
    }

    func testJoinedTextEmpty() {
        let store = ProxyLogStore()
        let joined = store.joinedText
        XCTAssertEqual(joined, "")
    }

    func testJoinedTextSingleLine() {
        let store = ProxyLogStore()
        store.append("only")
        let joined = store.joinedText
        XCTAssertEqual(joined, "only")
    }

    func testThreadSafety() {
        let store = ProxyLogStore(capacity: 100)
        let expectation = XCTestExpectation(description: "concurrent appends")
        expectation.expectedFulfillmentCount = 10

        for i in 0..<10 {
            DispatchQueue.global().async {
                for j in 0..<10 {
                    store.append("thread\(i)-line\(j)")
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 2.0)
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.count, 100)
    }
}
