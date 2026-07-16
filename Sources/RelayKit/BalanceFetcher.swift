import Foundation

public struct BalanceFetcher: Sendable {
    private static let url = URL(string: "https://api.deepseek.com/user/balance")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(apiKey: String) async throws -> Double {
        var req = URLRequest(url: Self.url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw BalanceError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try Self.parse(data)
    }

    private static func parse(_ data: Data) throws -> Double {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isAvailable = json["is_available"] as? Bool, isAvailable,
              let balances = json["balance_infos"] as? [[String: Any]] else {
            throw BalanceError.unexpectedFormat
        }
        var total = 0.0
        for b in balances {
            if let currency = b["currency"] as? String, currency == "USD",
               let bal = b["total_balance"] as? String, let val = Double(bal) {
                total += val
            }
        }
        return total
    }
}

public enum BalanceError: Error, CustomStringConvertible {
    case badResponse(Int)
    case unexpectedFormat

    public var description: String {
        switch self {
        case .badResponse(let code): return "Balance endpoint returned \(code)"
        case .unexpectedFormat: return "Unexpected balance response format"
        }
    }
}
