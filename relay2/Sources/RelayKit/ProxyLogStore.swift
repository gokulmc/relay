import Foundation

/// Thread-safe ring buffer of proxy stdout/stderr lines for the log viewer.
public final class ProxyLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    public func appendChunk(_ chunk: String) {
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line)
            if !trimmed.isEmpty {
                append(trimmed)
            }
        }
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }

    public var joinedText: String {
        snapshot().joined(separator: "\n")
    }
}
