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
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
        "/usr/bin/python3",
    ]

    /// Upper bound (inclusive) of the version range preferred on a first pass. PyPI wheel
    /// availability lags new Python releases — packages with compiled extensions (e.g.
    /// litellm's `orjson` dependency, built via Rust/PyO3) routinely fail to build against a
    /// Python version newer than what the toolchain currently supports. A too-new interpreter
    /// (found via a generic `python3` symlink tracking Homebrew's "current" version) is
    /// preferred only as a last resort, once no better-supported version is available.
    private static let preferredMaxMinor = 13

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
        var usable: [(path: String, major: Int, minor: Int)] = []

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

                usable.append((path, parts[0], parts[1]))
            } catch {
                failures.append("\(path): \(error.localizedDescription)")
            }
        }

        // First pass: prefer the newest version within the known-wheel-compatible range, so a
        // too-new interpreter never wins over a well-supported one just by appearing first in
        // the candidate list.
        let inRange = usable.filter { $0.major == 3 && $0.minor <= Self.preferredMaxMinor }
        if let best = inRange.max(by: { $0.minor < $1.minor }) {
            return best.path
        }
        // Fallback: nothing in the preferred range — take the newest usable interpreter anyway,
        // rather than failing outright, since it may still work for pure-Python dependencies.
        if let best = usable.max(by: { ($0.major, $0.minor) < ($1.major, $1.minor) }) {
            return best.path
        }

        throw PythonProbeError.noUsablePython(failures.joined(separator: "\n"))
    }
}
