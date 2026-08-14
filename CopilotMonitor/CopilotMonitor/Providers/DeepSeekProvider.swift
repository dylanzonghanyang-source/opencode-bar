import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "DeepSeekProvider")

/// Provider for DeepSeek pay-as-you-go balance tracking.
///
/// DeepSeek is billed as prepaid credit: the account carries a CNY balance
/// (split into topped-up and granted parts) reported by the official
/// `GET https://api.deepseek.com/user/balance` endpoint. There is no quota
/// window or utilization percentage — the balance is the only metric, so we
/// surface it through `payAsYouGo` cost (excluded from the aggregate spend
/// total) plus `DetailedUsage.balance*` fields for the detail menu.
final class DeepSeekProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .deepSeek
    let type: ProviderType = .payAsYouGo

    private let tokenManager: TokenManager
    private let session: URLSession

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared) {
        self.tokenManager = tokenManager
        self.session = session
    }

    // MARK: - API Response Structures

    /// Response structure for /user/balance
    struct BalanceResponse: Decodable {
        let isAvailable: Bool?
        let balanceInfos: [BalanceInfo]?

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    struct BalanceInfo: Decodable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        logger.info("DeepSeek balance fetch started")

        guard let apiKey = tokenManager.getDeepSeekAPIKey() else {
            logger.error("DeepSeek API key not found")
            throw ProviderError.authenticationFailed("DeepSeek API key not available")
        }

        let balanceResponse = try await fetchBalance(apiKey: apiKey)

        guard let info = balanceResponse.balanceInfos?.first else {
            logger.error("DeepSeek balance response missing balance_infos")
            throw ProviderError.decodingError("Missing balance_infos")
        }

        let totalBalance = Double(info.totalBalance ?? "") ?? 0.0
        let grantedBalance = Double(info.grantedBalance ?? "") ?? 0.0
        let toppedUpBalance = Double(info.toppedUpBalance ?? "") ?? 0.0
        let currency = info.currency ?? "CNY"

        logger.info("DeepSeek balance fetched: \(currency) \(String(format: "%.2f", totalBalance)) (granted: \(String(format: "%.2f", grantedBalance)), topped-up: \(String(format: "%.2f", toppedUpBalance)))")

        let details = DetailedUsage(
            creditsBalance: totalBalance,
            balanceCurrency: currency,
            balanceGranted: grantedBalance,
            balanceToppedUp: toppedUpBalance,
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        )

        // `cost` carries the balance for the menu row; the aggregate spend
        // calculation explicitly excludes `.deepSeek` so the balance is never
        // counted as money already spent.
        return ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: totalBalance, resetsAt: nil),
            details: details
        )
    }

    // MARK: - Private API Methods

    /// Fetches the account balance from the DeepSeek API
    /// - Parameter apiKey: DeepSeek API key
    /// - Returns: BalanceResponse containing balance_infos
    private func fetchBalance(apiKey: String) async throws -> BalanceResponse {
        let endpoint = "https://api.deepseek.com/user/balance"

        guard let url = URL(string: endpoint) else {
            logger.error("Invalid balance endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from balance API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Balance API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            logger.error("Failed to decode balance response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }
}
