import Foundation

public enum PythonProbeError: Error, CustomStringConvertible, Equatable {
    case noUsablePython(String)

    public var description: String {
        switch self {
        case .noUsablePython(let detail):
            return "No usable python3 found.\n\(detail)"
        }
    }
}

public struct PythonProbe: Sendable {
    public static let defaultCandidates = [
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
        "/usr/bin/python3",
    ]

    private let candidates: [String]
    private let runner: any ProcessRunning
    private let fileExists: @Sendable (String) -> Bool

    public init(
        candidates: [String] = PythonProbe.defaultCandidates,
        runner: any ProcessRunning = FoundationProcessRunner(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.candidates = candidates
        self.runner = runner
        self.fileExists = fileExists
    }

    public func find() async throws -> String {
        var failures: [String] = []

        for path in candidates {
            if !fileExists(path) {
                failures.append("\(path): not found")
                continue
            }

            do {
                let version = try await runner.run(
                    command: path,
                    arguments: ["-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
                    environment: nil,
                    workingDirectory: nil
                )
                guard version.succeeded else {
                    failures.append("\(path): version check failed (\(version.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
                    continue
                }
                let parts = version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ".")
                    .compactMap { Int($0) }
                guard parts.count >= 2, parts[0] > 3 || (parts[0] == 3 && parts[1] >= 9) else {
                    failures.append("\(path): needs Python >= 3.9 (got \(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))")
                    continue
                }

                let ensurepip = try await runner.run(
                    command: path,
                    arguments: ["-c", "import ensurepip"],
                    environment: nil,
                    workingDirectory: nil
                )
                guard ensurepip.succeeded else {
                    failures.append("\(path): missing ensurepip (likely Xcode CLT stub)")
                    continue
                }

                return path
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }

        throw PythonProbeError.noUsablePython(failures.joined(separator: "\n"))
    }
}
