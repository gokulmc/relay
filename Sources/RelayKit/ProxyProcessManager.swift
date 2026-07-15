import Darwin
import Foundation

public enum ProxyStatus: Equatable, Sendable {
    case stopped
    case starting
    case running
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running (port \(AppSupport.defaultPort))"
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}

public final class ProxyProcessManager: @unchecked Sendable {
    public typealias HealthCheck = @Sendable (Int) async -> Bool
    public typealias PathForPID = @Sendable (Int32) -> String?

    private let appSupportDir: URL
    private let port: Int
    private let logStore: ProxyLogStore
    private let healthCheck: HealthCheck
    private let pathForPID: PathForPID
    private let fileManager: FileManager
    private let healthTimeout: TimeInterval

    private let state = ProxyState()

    public var status: ProxyStatus {
        state.status
    }

    public var pidFileURL: URL {
        appSupportDir.appendingPathComponent("proxy.pid")
    }

    public var litellmURL: URL {
        appSupportDir.appendingPathComponent("venv/bin/litellm")
    }

    public var configURL: URL {
        appSupportDir.appendingPathComponent("litellm-config.yaml")
    }

    public init(
        appSupportDir: URL = AppSupport.defaultDirectory(),
        port: Int = AppSupport.defaultPort,
        logStore: ProxyLogStore = ProxyLogStore(),
        healthCheck: HealthCheck? = nil,
        pathForPID: PathForPID? = nil,
        fileManager: FileManager = .default,
        healthTimeout: TimeInterval = 10
    ) {
        self.appSupportDir = appSupportDir
        self.port = port
        self.logStore = logStore
        self.healthCheck = healthCheck ?? { port in
            await ProxyHealthChecker().check(port: port)
        }
        self.pathForPID = pathForPID ?? { pid in
            ProxyProcessManager.defaultPathForPID(pid)
        }
        self.fileManager = fileManager
        self.healthTimeout = healthTimeout
    }

    public var logs: ProxyLogStore { logStore }

    /// Reconcile pidfile + live process + health at app launch. Never auto-starts.
    @discardableResult
    public func reconcileAtStartup() async -> ProxyStatus {
        guard let pid = readPIDFile() else {
            setStatus(.stopped)
            return .stopped
        }

        if !isProcessAlive(pid) {
            clearPIDFile()
            setStatus(.stopped)
            return .stopped
        }

        if let path = pathForPID(pid), !path.contains("venv/bin/litellm") {
            clearPIDFile()
            setStatus(.stopped)
            return .stopped
        }

        setStatus(.starting)
        if await waitForHealthy(timeout: 5) {
            state.adoptedPID = pid
            setStatus(.running)
            return .running
        }

        setStatus(.failed("proxy process is alive but not healthy"))
        return status
    }

    public func start(environment: [String: String]) async throws {
        if case .running = status { return }
        if case .starting = status { return }

        guard fileManager.isExecutableFile(atPath: litellmURL.path) else {
            setStatus(.failed("LiteLLM binary missing — Repair the environment first"))
            throw ProxyError.missingBinary(litellmURL.path)
        }
        guard fileManager.fileExists(atPath: configURL.path) else {
            setStatus(.failed("LiteLLM config missing"))
            throw ProxyError.missingConfig(configURL.path)
        }

        setStatus(.starting)
        state.intentionalStop = false
        logStore.append("Starting LiteLLM on port \(port)…")

        let process = Process()
        process.executableURL = litellmURL
        process.arguments = ["--config", configURL.path, "--port", "\(port)"]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = FoundationProcessRunner.processPATH
        for (key, value) in environment {
            env[key] = value
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let store = logStore
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            store.appendChunk(text)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            store.appendChunk(text)
        }

        process.terminationHandler = { [weak self] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.clearPIDFile()
            self.state.process = nil
            self.state.adoptedPID = nil
            // Intentional stop() uses SIGTERM (exit 15) — treat as clean stop, not failure.
            if self.state.intentionalStop || finished.terminationStatus == 0 {
                self.state.intentionalStop = false
                self.setStatus(.stopped)
                store.append("LiteLLM stopped")
            } else {
                self.setStatus(.failed("exited with code \(finished.terminationStatus)"))
                store.append("LiteLLM exited with code \(finished.terminationStatus)")
            }
        }

        do {
            try process.run()
        } catch {
            setStatus(.failed(error.localizedDescription))
            throw error
        }

        state.process = process
        writePIDFile(process.processIdentifier)

        if await waitForHealthy(timeout: healthTimeout) {
            setStatus(.running)
            logStore.append("Proxy healthy on port \(port)")
        } else {
            process.terminate()
            clearPIDFile()
            setStatus(.failed("proxy did not become healthy"))
            throw ProxyError.unhealthy
        }
    }

    public func stop() {
        state.intentionalStop = true
        let running = state.process
        let adopted = state.adoptedPID

        if let running, running.isRunning {
            let pid = running.processIdentifier
            running.terminate()
            // Give it a moment; terminationHandler clears state.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if running.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        } else if let adopted {
            kill(adopted, SIGTERM)
        }

        clearPIDFile()
        setStatus(.stopped)
    }

    // MARK: - Internals

    private func setStatus(_ status: ProxyStatus) {
        state.status = status
    }

    private func waitForHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await healthCheck(port) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    private func writePIDFile(_ pid: Int32) {
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func readPIDFile() -> Int32? {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func clearPIDFile() {
        try? fileManager.removeItem(at: pidFileURL)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func defaultPathForPID(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }
}

private final class ProxyState: @unchecked Sendable {
    private let lock = NSLock()
    private var _status: ProxyStatus = .stopped
    private var _process: Process?
    private var _adoptedPID: Int32?
    private var _intentionalStop = false

    var status: ProxyStatus {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    var process: Process? {
        get { lock.lock(); defer { lock.unlock() }; return _process }
        set { lock.lock(); _process = newValue; lock.unlock() }
    }

    var adoptedPID: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _adoptedPID }
        set { lock.lock(); _adoptedPID = newValue; lock.unlock() }
    }

    var intentionalStop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _intentionalStop }
        set { lock.lock(); _intentionalStop = newValue; lock.unlock() }
    }
}

public enum ProxyError: Error, CustomStringConvertible {
    case missingBinary(String)
    case missingConfig(String)
    case unhealthy

    public var description: String {
        switch self {
        case .missingBinary(let path): return "Missing LiteLLM binary at \(path)"
        case .missingConfig(let path): return "Missing LiteLLM config at \(path)"
        case .unhealthy: return "Proxy did not become healthy"
        }
    }
}
