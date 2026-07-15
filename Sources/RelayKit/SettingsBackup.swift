import Foundation

public enum SettingsBackupError: Error, CustomStringConvertible {
    case sourceMissing(URL)
    case copyFailed(String)

    public var description: String {
        switch self {
        case .sourceMissing(let url):
            return "Cannot back up missing file: \(url.path)"
        case .copyFailed(let message):
            return "Backup failed: \(message)"
        }
    }
}

public struct SettingsBackup {
    private let backupsDirectory: URL

    public init(appSupportDir: URL = AppSupport.defaultDirectory()) {
        self.backupsDirectory = appSupportDir.appendingPathComponent("backups", isDirectory: true)
    }

    /// Copies `sourceURL` to `backups/<filename>.<ISO8601-timestamp>.bak`.
    @discardableResult
    public func backup(sourceURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SettingsBackupError.sourceMissing(sourceURL)
        }
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "\(sourceURL.lastPathComponent).\(stamp).bak"
        let destination = backupsDirectory.appendingPathComponent(name)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw SettingsBackupError.copyFailed(error.localizedDescription)
        }
        return destination
    }
}
