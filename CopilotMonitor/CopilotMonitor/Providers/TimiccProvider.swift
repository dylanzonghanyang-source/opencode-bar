import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "TimiccProvider")

/// Provider for TIMICC pay-as-you-go balance tracking.
///
/// TIMICC is billed as prepaid USD credit. The account balance and usage are
/// reported by `GET https://timicc.com/v1/usage` authenticated with the same
/// API key used for model calls. The response includes balance, remaining,
/// unit, daily usage, per-model stats and today/total usage — this first
/// version only surfaces the balance + unit; the richer fields are parsed
/// (and kept in the model) for future expansion without complicating the UI.
final class TimiccProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .timicc
    let type: ProviderType = .payAsYouGo

    private let tokenManager: TokenManager
    private let session: URLSession
    /// Optional injected API key for tests; falls back to the credential store.
    private let apiKeyOverride: String?

    init(tokenManager: TokenManager = .shared, session: URLSession = .shared, apiKey: String? = nil) {
        self.tokenManager = tokenManager
        self.session = session
        self.apiKeyOverride = apiKey
    }

    // MARK: - API Response Structures

    /// Response structure for /v1/usage
    struct UsageResponse: Decodable {
        let balance: Double?
        let dailyUsage: [DailyUsage]?
        let isValid: Bool?
        let mode: String?
        let modelStats: [ModelStat]?
        let planName: String?
        let remaining: Double?
        let unit: String?
        let usage: UsageSummary?

        enum CodingKeys: String, CodingKey {
            case balance
            case dailyUsage = "daily_usage"
            case isValid
            case mode
            case modelStats = "model_stats"
            case planName
            case remaining
            case unit
            case usage
        }
    }

    struct DailyUsage: Decodable {
        let date: String?
        let requests: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let totalTokens: Int?
        let cost: Double?
        let actualCost: Double?

        enum CodingKeys: String, CodingKey {
            case date
            case requests
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cacheWriteTokens = "cache_write_tokens"
            case totalTokens = "total_tokens"
            case cost
            case actualCost = "actual_cost"
        }
    }

    struct ModelStat: Decodable {
        let model: String?
        let requests: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationTokens: Int?
        let cacheReadTokens: Int?
        let totalTokens: Int?
        let cost: Double?

        enum CodingKeys: String, CodingKey {
            case model
            case requests
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationTokens = "cache_creation_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case totalTokens = "total_tokens"
            case cost
        }
    }

    struct UsageSummary: Decodable {
        let averageDurationMs: Double?
        let rpm: Int?
        let today: UsageWindow?
        let total: UsageWindow?

        enum CodingKeys: String, CodingKey {
            case averageDurationMs = "average_duration_ms"
            case rpm
            case today
            case total
        }
    }

    struct UsageWindow: Decodable {
        let actualCost: Double?
        let cacheCreationTokens: Int?
        let cacheReadTokens: Int?
        let cost: Double?
        let inputTokens: Int?
        let outputTokens: Int?
        let requests: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case actualCost = "actual_cost"
            case cacheCreationTokens = "cache_creation_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case cost
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case requests
            case totalTokens = "total_tokens"
        }
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        logger.info("TIMICC balance fetch started")

        guard let apiKey = apiKeyOverride ?? tokenManager.getTimiccAPIKey() else {
            logger.error("TIMICC API key not found")
            throw ProviderError.authenticationFailed("TIMICC API key not available")
        }

        let response = try await fetchUsage(apiKey: apiKey)

        guard let balance = response.balance ?? response.remaining else {
            logger.error("TIMICC usage response missing balance")
            throw ProviderError.decodingError("Missing balance")
        }

        let unit = response.unit ?? "USD"

        logger.info("TIMICC balance fetched: \(unit) \(String(format: "%.2f", balance)) (mode: \(response.mode ?? "unknown"))")

        let details = DetailedUsage(
            creditsBalance: balance,
            balanceCurrency: unit,
            authSource: tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        )

        // `cost` stays nil: it represents money already spent, while TIMICC
        // reports money remaining. The menu row reads the balance from details
        // and the aggregate spend total never counts this provider.
        return ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: details
        )
    }

    // MARK: - Private API Methods

    /// Fetches balance + usage from the TIMICC usage endpoint
    /// - Parameter apiKey: TIMICC API key
    /// - Returns: UsageResponse containing balance and usage details
    private func fetchUsage(apiKey: String) async throws -> UsageResponse {
        let endpoint = "https://timicc.com/v1/usage"

        guard let url = URL(string: endpoint) else {
            logger.error("Invalid usage endpoint URL")
            throw ProviderError.networkError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Invalid response type from usage API")
            throw ProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("Usage API request failed with status code: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            logger.error("Failed to decode usage response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }
}
