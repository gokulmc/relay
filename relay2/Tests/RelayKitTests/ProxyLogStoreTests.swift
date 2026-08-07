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

    // MARK: - File logging

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    func testFileLoggingWritesLinesToDisk() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        let store = ProxyLogStore(fileURL: fileURL)

        store.append("hello world")
        store.appendChunk("second\nthird")

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("hello world"))
        XCTAssertTrue(contents.contains("second"))
        XCTAssertTrue(contents.contains("third"))
        XCTAssertEqual(store.logFileURL, fileURL)
    }

    func testFileLoggingWritesSessionStartMarker() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        _ = ProxyLogStore(fileURL: fileURL)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("=== proxy log session started"))
    }

    func testFileLoggingPrefixesPersistedLinesWithISO8601Timestamp() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        let store = ProxyLogStore(fileURL: fileURL)

        store.append("boom")

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let boomLine = contents.split(separator: "\n").map(String.init).first { $0.contains("boom") }
        XCTAssertNotNil(boomLine)
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z {2}boom$"#
        XCTAssertNotNil(boomLine?.range(of: pattern, options: .regularExpression))
    }

    func testFileLoggingKeepsSnapshotAndJoinedTextRawAndTimestampFree() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        let store = ProxyLogStore(fileURL: fileURL)

        store.append("line1")
        store.append("line2")

        XCTAssertEqual(store.snapshot(), ["line1", "line2"])
        XCTAssertEqual(store.joinedText, "line1\nline2")
    }

    func testRotationCreatesArchiveAndShrinksCurrentFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        let store = ProxyLogStore(fileURL: fileURL, maxBytes: 200)

        var totalBytesAppended = 0
        for i in 0..<50 {
            let line = "line number \(i) with some padding text to grow the file"
            // Matches the on-disk "<20-char ISO8601Z timestamp><2 spaces><line>\n" format.
            totalBytesAppended += 20 + 2 + line.utf8.count + 1
            store.append(line)
        }

        let archive1 = fileURL.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive1.path))

        let currentSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? -1
        let archiveSize = try FileManager.default.attributesOfItem(atPath: archive1.path)[.size] as? Int ?? -1
        XCTAssertGreaterThanOrEqual(archiveSize, 200)
        // Rotation happened at least once, so the current file can't hold everything
        // that was ever written to it — it's far smaller than the un-rotated total.
        XCTAssertLessThan(currentSize, totalBytesAppended / 2)
    }

    func testRotationDeletesArchivesBeyondRetentionLimit() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let fileURL = dir.appendingPathComponent("proxy.log")
        let store = ProxyLogStore(fileURL: fileURL, maxBytes: 100)

        for i in 0..<300 {
            store.append("line \(i) with enough padding text to force several rotations")
        }

        let archive1 = fileURL.appendingPathExtension("1")
        let archive2 = fileURL.appendingPathExtension("2")
        let archive3 = fileURL.appendingPathExtension("3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive3.path))
    }

    func testMemoryOnlyStoreWritesNothingToDisk() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let wouldBeFileURL = dir.appendingPathComponent("proxy.log")

        let store = ProxyLogStore()
        store.append("only memory")

        XCTAssertNil(store.logFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wouldBeFileURL.path))
        XCTAssertEqual(store.snapshot(), ["only memory"])
    }
}
