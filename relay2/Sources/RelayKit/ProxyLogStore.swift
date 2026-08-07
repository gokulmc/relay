import Foundation

/// Thread-safe ring buffer of proxy stdout/stderr lines for the log viewer.
///
/// Optionally also persists every line to a rotating on-disk file so proxy output
/// survives app restarts (the in-memory ring buffer alone does not — it's the reason
/// a provider failure couldn't be diagnosed after the fact). File logging is strictly
/// additive: the in-memory buffer, `snapshot()`, and `joinedText` are unaffected and
/// keep returning raw, timestamp-free lines.
public final class ProxyLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    private let maxBytes: Int

    /// Non-nil only while file logging is active for this instance. Starts nil when
    /// no `fileURL` is given, and reverts to nil permanently if opening or writing
    /// ever fails — file logging failures must never surface as crashes, so on any
    /// I/O error we silently fall back to memory-only for the rest of the process.
    public private(set) var logFileURL: URL?

    private var fileHandle: FileHandle?
    private var currentFileSize: Int = 0
    private static let timestampFormatter = ISO8601DateFormatter()

    /// - Parameters:
    ///   - capacity: max in-memory lines kept for the log viewer (unchanged behavior).
    ///   - fileURL: where to persist a rotating copy of the log. `nil` (the default)
    ///     means memory-only, which is what every existing call site/test gets.
    ///   - maxBytes: size threshold that triggers rotation of the current file.
    public init(capacity: Int = 500, fileURL: URL? = nil, maxBytes: Int = 2 * 1024 * 1024) {
        self.capacity = capacity
        self.maxBytes = maxBytes
        if let fileURL {
            openFile(at: fileURL)
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
        persistLocked(line)
    }

    /// Logs an app-level event (e.g. a switch failure that happened before the proxy
    /// subprocess ever started, so it would otherwise never reach this file). Routes
    /// through `append` so it gets the same timestamping and persistence as proxy
    /// output, with an `[app]` marker to distinguish it from proxy lines on disk.
    public func appendAppEvent(_ message: String) {
        append("[app] \(message)")
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

    // MARK: - File logging

    /// Opens (creating if needed) the rotating log file and writes a session-start
    /// marker so restarts are visible when reading the file back later. Any failure
    /// along the way — directory creation, file open — leaves `logFileURL` nil and
    /// this instance permanently memory-only; callers never see an error for this.
    private func openFile(at url: URL) {
        let fm = FileManager.default
        do {
            try AppSupport.ensureDirectory(url.deletingLastPathComponent())
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            // Re-sync the in-memory byte count from the file itself rather than
            // trusting any prior state — the one stat-equivalent we do per open,
            // not per line.
            currentFileSize = Int(handle.offsetInFile)
            fileHandle = handle
            logFileURL = url
            writeRaw("=== proxy log session started \(Self.timestampFormatter.string(from: Date())) ===\n")
        } catch {
            fileHandle = nil
            logFileURL = nil
        }
    }

    /// Appends the timestamped, newline-terminated form of `line` to disk, rotating
    /// first if the file has already grown past `maxBytes`. Called with `lock` held.
    private func persistLocked(_ line: String) {
        guard fileHandle != nil else { return }
        if currentFileSize >= maxBytes {
            rotate()
        }
        let timestamp = Self.timestampFormatter.string(from: Date())
        writeRaw("\(timestamp)  \(line)\n")
    }

    /// Writes raw bytes to the open handle and updates the tracked size. Any failure
    /// (full disk, revoked permissions, etc.) disables file logging for the rest of
    /// this instance rather than throwing — the whole point is diagnostics must
    /// never be the thing that takes the app down.
    private func writeRaw(_ text: String) {
        guard let handle = fileHandle, let data = text.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            currentFileSize += data.count
        } catch {
            fileHandle = nil
            logFileURL = nil
        }
    }

    /// Rotates `proxy.log` -> `.1` -> `.2`, dropping anything older than `.2`, then
    /// opens a fresh empty current file. Called with `lock` held, from `persistLocked`.
    private func rotate() {
        guard let url = logFileURL else { return }
        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        let archive1 = url.appendingPathExtension("1")
        let archive2 = url.appendingPathExtension("2")

        try? fm.removeItem(at: archive2)
        if fm.fileExists(atPath: archive1.path) {
            try? fm.moveItem(at: archive1, to: archive2)
        }
        try? fm.moveItem(at: url, to: archive1)

        guard fm.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            logFileURL = nil
            return
        }
        fileHandle = handle
        currentFileSize = 0
    }
}
