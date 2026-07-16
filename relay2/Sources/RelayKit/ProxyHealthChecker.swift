import Foundation

public struct ProxyHealthChecker: Sendable {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 2.0, session: URLSession? = nil) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: config)
        }
    }

    public func check(port: Int = AppSupport.defaultPort) async -> Bool {
        // Use LiteLLM's liveness probe, NOT `/health`. The plain `/health` endpoint requires the
        // master key (returns 500 unauthenticated) and actively pings every upstream model, so it
        // can never be a fast, unauthenticated readiness signal. `/health/liveliness` returns 200
        // as soon as the server is accepting requests, with no auth and no upstream calls.
        guard let url = URL(string: "http://127.0.0.1:\(port)/health/liveliness") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
