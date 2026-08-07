import Foundation

public enum InstallStatus: Equatable, Sendable {
    case alreadyInstalled
    case installed
}

public enum VenvInstallError: Error, CustomStringConvertible, Equatable {
    case noUsablePython(String)
    case venvCreationFailed(String)
    case pipInstallFailed(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .noUsablePython(let detail):
            return detail
        case .venvCreationFailed(let stderr):
            return "Failed to create Python venv:\n\(stderr)"
        case .pipInstallFailed(let stderr):
            return "Failed to install litellm[proxy]:\n\(stderr)"
        case .verificationFailed(let detail):
            return "LiteLLM verification failed:\n\(detail)"
        }
    }

    public var message: String { description }
}

public struct VenvInstaller {
    public let appSupportDir: URL
    private let runner: any ProcessRunning
    private let probe: PythonProbe
    private let fileManager: FileManager

    public init(
        appSupportDir: URL = AppSupport.defaultDirectory(),
        runner: any ProcessRunning = FoundationProcessRunner(),
        probe: PythonProbe? = nil,
        fileManager: FileManager = .default
    ) {
        self.appSupportDir = appSupportDir
        self.runner = runner
        self.probe = probe ?? PythonProbe(runner: runner)
        self.fileManager = fileManager
    }

    public var venvURL: URL {
        appSupportDir.appendingPathComponent("venv", isDirectory: true)
    }

    public var callbackURL: URL {
        appSupportDir.appendingPathComponent("\(AppSupport.groqVisionCallbackModule).py")
    }

    public var litellmURL: URL {
        venvURL.appendingPathComponent("bin/litellm")
    }

    public var pipURL: URL {
        venvURL.appendingPathComponent("bin/pip")
    }

    public func ensureReady() async throws -> InstallStatus {
        if await isHealthy() {
            return .alreadyInstalled
        }
        try await install(force: false)
        return .installed
    }

    public func reinstall() async throws -> InstallStatus {
        if fileManager.fileExists(atPath: venvURL.path) {
            try fileManager.removeItem(at: venvURL)
        }
        try await install(force: true)
        return .installed
    }

    /// Copy the Groq vision callback .py file from `sourceURL` (a bundled resource)
    /// to the app support directory so LiteLLM can import it.
    public func installCallback(from sourceURL: URL) throws {
        try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: callbackURL.path) {
            try fileManager.removeItem(at: callbackURL)
        }
        try fileManager.copyItem(at: sourceURL, to: callbackURL)
    }

    private func isHealthy() async -> Bool {
        guard fileManager.isExecutableFile(atPath: litellmURL.path) else { return false }
        do {
            let outcome = try await runner.run(
                command: litellmURL.path,
                arguments: ["--version"],
                environment: nil,
                workingDirectory: nil
            )
            return outcome.succeeded
        } catch {
            return false
        }
    }

    /// Exposed so a test can guard the fastapi ceiling (see the comment at the call site) —
    /// losing it silently reinstalls a proxy that can't start.
    static let pipInstallArguments = [
        "install", "litellm[proxy]", "prometheus-client", "fastapi>=0.136.3,<0.140.1",
    ]

    private func install(force _: Bool) async throws {
        try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        let python: String
        do {
            python = try await probe.find()
        } catch let error as PythonProbeError {
            throw VenvInstallError.noUsablePython(error.description)
        }

        if fileManager.fileExists(atPath: venvURL.path) {
            try? fileManager.removeItem(at: venvURL)
        }

        let venvResult = try await runner.run(
            command: python,
            arguments: ["-m", "venv", venvURL.path],
            environment: nil,
            workingDirectory: nil
        )
        guard venvResult.succeeded else {
            throw VenvInstallError.venvCreationFailed(tail(venvResult.stderr, lines: 30))
        }

        // Best-effort pip upgrade — don't fail the whole install if this step fails.
        _ = try? await runner.run(
            command: pipURL.path,
            arguments: ["install", "--upgrade", "pip"],
            environment: nil,
            workingDirectory: nil
        )

        // prometheus_client isn't bundled with litellm[proxy] — without it, enabling the
        // prometheus callback (for usage tracking) crashes the proxy on startup with
        // ModuleNotFoundError.
        //
        // The fastapi ceiling is load-bearing: litellm only asks for `fastapi>=0.136.3,<1.0`,
        // but FastAPI dropped `get_flat_dependant` in 0.140.1 while litellm's proxy still
        // imports it. An unpinned install therefore resolves to a fastapi that makes the proxy
        // die at startup with an ImportError — and because this runs on Repair too, a "repair"
        // silently reinstalled the breakage. Keep the ceiling until litellm stops using it.
        let pipResult = try await runner.run(
            command: pipURL.path,
            arguments: Self.pipInstallArguments,
            environment: nil,
            workingDirectory: nil
        )
        guard pipResult.succeeded else {
            throw VenvInstallError.pipInstallFailed(tail(pipResult.stderr, lines: 30))
        }

        let verify = try await runner.run(
            command: litellmURL.path,
            arguments: ["--version"],
            environment: nil,
            workingDirectory: nil
        )
        guard verify.succeeded else {
            throw VenvInstallError.verificationFailed(tail(verify.stderr.isEmpty ? verify.stdout : verify.stderr, lines: 30))
        }
    }

    private func tail(_ text: String, lines: Int) -> String {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.count <= lines { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
