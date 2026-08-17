import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "DashScopeProvider")

/// Provider for Alibaba Cloud DashScope / Bailian pay-as-you-go balance tracking.
///
/// DashScope (Bailian Model Studio) is billed against the Alibaba Cloud
/// account cash balance. There is no public API-key balance endpoint, so the
/// provider reuses the account console session: it extracts the Alibaba login
/// cookies from the user's browser, exchanges them for a short-lived
/// `sec_token` via `/tool/user/info.json`, then calls the console RPC gateway
/// (`data/api.json`) with `action=QueryAccountBalance&product=BssOpenApi`.
///
/// The balance is surfaced through `DetailedUsage.creditsBalance` (plus
/// `balanceCurrency`) while `payAsYouGo.cost` stays nil: cost means money
/// spent, and a remaining balance must never count toward the aggregate
/// spend total.
final class DashScopeProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .dashScope
    let type: ProviderType = .payAsYouGo

    private let cookieService: BrowserCookieService
    private let session: URLSession
    /// Optional injected Cookie header for tests; falls back to browser extraction.
    private let cookieHeaderOverride: String?

    init(
        cookieService: BrowserCookieService = .shared,
        session: URLSession? = nil,
        cookieHeader: String? = nil
    ) {
        self.cookieService = cookieService
        if let session {
            self.session = session
        } else {
            // Dedicated ephemeral session: the shared session's
            // HTTPCookieStorage can hold stale Alibaba cookies that replace
            // our manually-set Cookie header before the request is sent.
            // httpShouldSetCookies=false keeps the hand-built header intact.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.cookieHeaderOverride = cookieHeader
    }

    // MARK: - API Response Structures

    /// `GET /tool/user/info.json` — exchanges the session cookies for a
    /// short-lived console security token.
    struct UserInfoResponse: Decodable {
        struct DataPayload: Decodable {
            let secToken: String?
        }
        let data: DataPayload?
    }

    /// `data/api.json?action=QueryAccountBalance&product=BssOpenApi`
    struct BalanceResponse: Decodable {
        struct DataPayload: Decodable {
            struct BalanceData: Decodable {
                /// Cash balance available for pay-as-you-go consumption (string-typed).
                let availableCashAmount: String?
                let currency: String?
                let availableAmount: String?

                enum CodingKeys: String, CodingKey {
                    case availableCashAmount = "AvailableCashAmount"
                    case currency = "Currency"
                    case availableAmount = "AvailableAmount"
                }
            }
            let data: BalanceData?

            enum CodingKeys: String, CodingKey {
                case data = "Data"
            }
        }
        let data: DataPayload?
    }

    // MARK: - ProviderProtocol

    func fetch() async throws -> ProviderResult {
        logger.info("DashScope balance fetch started")

        let cookieHeader: String
        if let override = cookieHeaderOverride, !override.isEmpty {
            cookieHeader = override
        } else {
            cookieHeader = try extractAlibabaCookieHeader()
        }

        // CSRF token rides in the login cookie; the console gateway expects it
        // in both x-xsrf-token and x-csrf-token headers.
        let csrf = Self.extractCookieValue(name: "login_aliyunid_csrf", from: cookieHeader)
            ?? Self.extractCookieValue(name: "csrf", from: cookieHeader)
        guard let csrf, !csrf.isEmpty else {
            logger.error("DashScope: missing login_aliyunid_csrf cookie (not logged into Alibaba Cloud?)")
            throw ProviderError.authenticationFailed("Alibaba Cloud login cookie not found — sign in at bailian.console.aliyun.com in Chrome")
        }

        let secToken = try await fetchSecToken(cookieHeader: cookieHeader)
        let balance = try await fetchBalance(cookieHeader: cookieHeader, csrf: csrf, secToken: secToken)

        guard let rawBalance = balance.data?.data?.availableCashAmount,
              let availableCash = Double(rawBalance) else {
            logger.error("DashScope balance response missing parseable AvailableCashAmount")
            throw ProviderError.decodingError("Missing AvailableCashAmount")
        }

        let currency = balance.data?.data?.currency ?? "CNY"
        logger.info("DashScope balance fetched: \(currency) \(String(format: "%.2f", availableCash))")

        let details = DetailedUsage(
            creditsBalance: availableCash,
            balanceCurrency: currency,
            authSource: "Chrome (Alibaba Cloud)"
        )

        return ProviderResult(
            usage: .payAsYouGo(utilization: 0, cost: nil, resetsAt: nil),
            details: details
        )
    }

    // MARK: - Private API Methods

    /// Extracts every Alibaba Cloud cookie from the user's browsers and joins
    /// them into a Cookie header string.
    private func extractAlibabaCookieHeader() throws -> String {
        var cookies: [BrowserCookie] = []
        for hostSuffix in ["aliyun.com", "alibabacloud.com"] {
            do {
                cookies.append(contentsOf: try cookieService.getCookies(hostSuffix: hostSuffix, names: []))
            } catch {
                logger.debug("No cookies for \(hostSuffix): \(error.localizedDescription)")
            }
        }

        // Prefer the most recent cookie per name (browser DB rows are ordered
        // by expires_utc DESC; keep first occurrence).
        var seen = Set<String>()
        let parts = cookies
            .filter { seen.insert($0.name).inserted }
            .map { "\($0.name)=\($0.value)" }

        guard !parts.isEmpty else {
            logger.error("DashScope: no Alibaba Cloud cookies found in any browser")
            throw ProviderError.authenticationFailed("No Alibaba Cloud login cookies found — sign in at bailian.console.aliyun.com in Chrome")
        }
        return parts.joined(separator: "; ")
    }

    /// Fetches the console `sec_token` from `/tool/user/info.json`.
    private func fetchSecToken(cookieHeader: String) async throws -> String {
        guard let url = URL(string: "https://billing-cost.console.aliyun.com/tool/user/info.json") else {
            throw ProviderError.networkError("Invalid user info endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.safariLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://billing-cost.console.aliyun.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logger.error("DashScope user info request failed: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            throw ProviderError.networkError("User info request failed")
        }

        do {
            let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            guard let secToken = info.data?.secToken, !secToken.isEmpty else {
                logger.error("DashScope user info response missing secToken (session expired?)")
                throw ProviderError.authenticationFailed("Alibaba Cloud console session expired — refresh bailian.console.aliyun.com in Chrome")
            }
            return secToken
        } catch let error as ProviderError {
            throw error
        } catch {
            logger.error("Failed to decode user info response: \(error.localizedDescription)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }

    /// Calls the console RPC gateway for the account balance.
    private func fetchBalance(cookieHeader: String, csrf: String, secToken: String) async throws -> BalanceResponse {
        var components = URLComponents(string: "https://billing-cost.console.aliyun.com/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "QueryAccountBalance"),
            URLQueryItem(name: "product", value: "BssOpenApi"),
            URLQueryItem(name: "params", value: "{}"),
            URLQueryItem(name: "region", value: "cn-beijing"),
            URLQueryItem(name: "sec_token", value: secToken)
        ]
        guard let url = components.url else {
            throw ProviderError.networkError("Invalid balance endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
        request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(Self.browserLikeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://billing-cost.console.aliyun.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "https://billing-cost.console.aliyun.com/fortune/fund-management/recharge",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ProviderError.authenticationFailed("HTTP \(httpResponse.statusCode) — Alibaba Cloud session expired")
            }
            logger.error("DashScope balance request failed with status: \(httpResponse.statusCode)")
            throw ProviderError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Diagnostic: surface unexpected payloads (e.g. PostonlyOrTokenError
        // from a stale sec_token) instead of a generic decode failure.
        let rawBody = String(data: data.prefix(400), encoding: .utf8) ?? "<binary>"
        if rawBody.contains("PostonlyOrTokenError") || rawBody.contains("ConsoleNeedLogin") {
            logger.error("DashScope balance RPC rejected: \(rawBody)")
            throw ProviderError.authenticationFailed("Alibaba Cloud rejected the console session (\(rawBody.prefix(80)))")
        }

        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            logger.error("Failed to decode balance response: \(error.localizedDescription) body=\(rawBody)")
            throw ProviderError.decodingError(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private static let browserLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private static let safariLikeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.3 Safari/605.1.15"

    /// Extracts a single cookie value from a Cookie header string.
    static func extractCookieValue(name: String, from cookieHeader: String) -> String? {
        for part in cookieHeader.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let pair = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines) == name {
                return String(pair[1])
            }
        }
        return nil
    }
}
