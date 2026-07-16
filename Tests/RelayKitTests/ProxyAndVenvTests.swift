import Foundation
import XCTest
@testable import RelayKit

final class ProxyAndVenvTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPythonProbeSkipsMissingAndPicksHealthy() async throws {
        let runner = FakeProcessRunner()
        // Candidate A missing from filesystem; B version ok + ensurepip ok.
        await runner.enqueueSuccess(stdout: "3.11\n")
        await runner.enqueueSuccess(stdout: "")

        let probe = PythonProbe(
            candidates: ["/missing/python3", "/tmp/fake-python3"],
            runner: runner,
            fileExists: { $0 == "/tmp/fake-python3" }
        )
        let path = try await probe.find()
        XCTAssertEqual(path, "/tmp/fake-python3")
    }

    func testPythonProbeThrowsWhenAllFail() async {
        let runner = FakeProcessRunner()
        let probe = PythonProbe(
            candidates: ["/nope"],
            runner: runner,
            fileExists: { _ in false }
        )
        do {
            _ = try await probe.find()
            XCTFail("expected failure")
        } catch is PythonProbeError {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testVenvInstallerAlreadyInstalledShortCircuit() async throws {
        let venvBin = tempDir.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: venvBin, withIntermediateDirectories: true)
        let litellm = venvBin.appendingPathComponent("litellm")
        try "#!/bin/sh\n".write(to: litellm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: litellm.path)

        let runner = FakeProcessRunner()
        await runner.enqueueSuccess(stdout: "litellm 1.0\n")

        let installer = VenvInstaller(appSupportDir: tempDir, runner: runner)
        let status = try await installer.ensureReady()
        XCTAssertEqual(status, .alreadyInstalled)
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments, ["--version"])
    }

    func testProxyProcessManagerReconcileNoPidfile() async {
        let manager = ProxyProcessManager(
            appSupportDir: tempDir,
            healthCheck: { _ in false },
            pathForPID: { _ in nil }
        )
        let status = await manager.reconcileAtStartup()
        XCTAssertEqual(status, .stopped)
    }

    func testProxyProcessManagerReconcileStalePidfile() async throws {
        let pidURL = tempDir.appendingPathComponent("proxy.pid")
        try "999999".write(to: pidURL, atomically: true, encoding: .utf8)
        let manager = ProxyProcessManager(
            appSupportDir: tempDir,
            healthCheck: { _ in true },
            pathForPID: { _ in "/tmp/venv/bin/litellm" }
        )
        let status = await manager.reconcileAtStartup()
        XCTAssertEqual(status, .stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidURL.path))
    }

    func testProxyProcessManagerReconcileWrongExecutable() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidURL = tempDir.appendingPathComponent("proxy.pid")
        try "\(pid)".write(to: pidURL, atomically: true, encoding: .utf8)

        let manager = ProxyProcessManager(
            appSupportDir: tempDir,
            healthCheck: { _ in true },
            pathForPID: { _ in "/usr/bin/something-else" }
        )
        let status = await manager.reconcileAtStartup()
        XCTAssertEqual(status, .stopped)
    }

    func testProxyProcessManagerReconcileHealthy() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let pidURL = tempDir.appendingPathComponent("proxy.pid")
        try "\(pid)".write(to: pidURL, atomically: true, encoding: .utf8)

        let manager = ProxyProcessManager(
            appSupportDir: tempDir,
            healthCheck: { _ in true },
            pathForPID: { _ in "/Users/test/Library/Application Support/Relay/venv/bin/litellm" }
        )
        let status = await manager.reconcileAtStartup()
        XCTAssertEqual(status, .running)
    }

    func testProxyHealthCheckerAgainstEphemeralServer() async throws {
        let server = TinyHTTPServer()
        let port = try server.start(statusCode: 200, body: #"{"ok":true}"#)
        defer { server.stop() }

        let checker = ProxyHealthChecker(timeout: 1.0)
        let ok = await checker.check(port: port)
        XCTAssertTrue(ok)

        // Regression guard: LiteLLM's plain `/health` requires the master key (500 without auth)
        // and pings upstream models, so the checker must hit the unauthenticated liveness probe.
        XCTAssertEqual(server.lastRequestPath, "/health/liveliness")

        let dead = await checker.check(port: port + 1)
        XCTAssertFalse(dead)
    }

    func testAppSupportBaseURLReflectsGivenPort() {
        XCTAssertEqual(AppSupport.baseURL(), "http://127.0.0.1:4000")
        XCTAssertEqual(AppSupport.baseURL(port: 4010), "http://127.0.0.1:4010")
    }

    func testProxyProcessManagerUpdatePortChangesStartArguments() async throws {
        let server = TinyHTTPServer()
        let realPort = try server.start(statusCode: 200, body: "ok")
        defer { server.stop() }

        let bin = tempDir.appendingPathComponent("venv/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let litellm = bin.appendingPathComponent("litellm")
        try "#!/bin/sh\nwhile true; do sleep 60; done\n".write(to: litellm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: litellm.path)
        try "model_list: []".write(
            to: tempDir.appendingPathComponent("litellm-config.yaml"), atomically: true, encoding: .utf8
        )

        let manager = ProxyProcessManager(
            appSupportDir: tempDir,
            port: 9999,
            healthCheck: { port in port == realPort },
            pathForPID: { _ in nil }
        )
        XCTAssertEqual(manager.currentPort, 9999)

        manager.updatePort(realPort)
        XCTAssertEqual(manager.currentPort, realPort)

        try await manager.start(environment: [:])
        XCTAssertEqual(manager.status, .running)
        manager.stop()
    }

    func testKeychainStoreRoundTrip() throws {
        let suffix = "test-\(UUID().uuidString)"
        let store = KeychainStore(serviceSuffix: suffix)
        let value = "relay-test-\(suffix)"
        // Keychain may be unavailable under SPM's sandbox — skip rather than fail CI.
        guard store.write(value, for: .liteLLMMasterKey) else {
            throw XCTSkip("Keychain write unavailable in this environment")
        }
        XCTAssertEqual(store.read(.liteLLMMasterKey), value)
        // Overwrite path (SecItemUpdate)
        XCTAssertTrue(store.write(value + "-2", for: .liteLLMMasterKey))
        XCTAssertEqual(store.read(.liteLLMMasterKey), value + "-2")
        store.delete(.liteLLMMasterKey)
        XCTAssertNil(store.read(.liteLLMMasterKey))
    }
}

/// Minimal localhost HTTP server for health-check tests.
final class TinyHTTPServer {
    private var socket: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "relay.test.http")
    private let pathLock = NSLock()
    private var _lastRequestPath: String?

    /// Request target of the most recent handled request (e.g. `/health/liveliness`).
    var lastRequestPath: String? {
        pathLock.lock(); defer { pathLock.unlock() }
        return _lastRequestPath
    }

    func start(statusCode: Int, body: String) throws -> Int {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw NSError(domain: "TinyHTTPServer", code: 1) }

        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw NSError(domain: "TinyHTTPServer", code: 2) }
        guard Darwin.listen(socket, 2) == 0 else { throw NSError(domain: "TinyHTTPServer", code: 3) }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &len)
            }
        }
        guard got == 0 else { throw NSError(domain: "TinyHTTPServer", code: 4) }
        let port = Int(UInt16(bigEndian: bound.sin_port))

        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = Darwin.accept(self.socket, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(client, &buffer, buffer.count)
            if n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8) {
                // Request line looks like: `GET /health/liveliness HTTP/1.1`
                let firstLine = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
                let fields = firstLine.split(separator: " ")
                if fields.count >= 2 {
                    self.pathLock.lock()
                    self._lastRequestPath = String(fields[1])
                    self.pathLock.unlock()
                }
            }
            let response = "HTTP/1.1 \(statusCode) OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            _ = response.withCString { Darwin.write(client, $0, strlen($0)) }
            Darwin.close(client)
        }
        source.resume()
        self.source = source
        return port
    }

    func stop() {
        source?.cancel()
        source = nil
        if socket >= 0 {
            Darwin.close(socket)
            socket = -1
        }
    }
}
