import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "XaiSuperGrokProvider")

/// Credential snapshot for OpenCode's read-only `xai` OAuth entry.
/// OpenCode owns refresh; this app never writes auth.json or uses the refresh token.
struct XaiOAuthCredential: Equatable {
    let accessToken: String
    let expiresAt: Date?
}

/// Minimal billing response used for SuperGrok unified quota monitoring.
struct XaiBillingResponse: Decodable {
    let config: XaiBillingConfig?
}

struct XaiBillingConfig: Decodable {
    let currentPeriod: XaiCurrentPeriod?
    /// USED percentage (not remaining). Zero may be omitted by protobuf-JSON.
    let creditUsagePercent: Double?
    /// Optional fallback reset timestamp if `currentPeriod.end` is absent.
    let billingPeriodEnd: String?

    private enum CodingKeys: String, CodingKey {
        case currentPeriod
        case creditUsagePercent
        case billingPeriodEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentPeriod = try container.decodeIfPresent(XaiCurrentPeriod.self, forKey: .currentPeriod)
        creditUsagePercent = Self.decodeDouble(container, forKey: .creditUsagePercent)
        billingPeriodEnd = try container.decodeIfPresent(String.self, forKey: .billingPeriodEnd)
    }

    private static func decodeDouble(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

struct XaiCurrentPeriod: Decodable {
    let type: String?
    let start: String?
    let end: String?
}

/// xAI SuperGrok quota provider authenticated via OpenCode's existing `xai` OAuth entry.
///
/// Separate from the existing `.grok` Grok CLI integration. This provider is bearer-token-only
/// against the Grok CLI chat proxy billing endpoint and does not refresh OAuth itself.
final class XaiSuperGrokProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .xaiSuperGrok
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 12.0
    let minimumFetchInterval: TimeInterval = 60.0

    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    private let tokenManager: TokenManager
    private let session: URLSession
    /// Optional injected credential for tests; falls back to OpenCode auth store.
    private let credentialOverride: XaiOAuthCredential?

    init(
        tokenManager: TokenManager = .shared,
        session: URLSession? = nil,
        credential: XaiOAuthCredential? = nil
    ) {
        self.tokenManager = tokenManager
        self.credentialOverride = credential
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
    }

    func fetch() async throws -> ProviderResult {
        logger.info("xAI SuperGrok fetch started")

        let credential: XaiOAuthCredential
        if let credentialOverride {
            credential = credentialOverride
        } else if let stored = tokenManager.getXaiOAuthCredential() {
            credential = stored
        } else {
            logger.error("xAI SuperGrok OAuth entry missing from OpenCode auth")
            throw ProviderError.authenticationFailed("xAI OAuth not available in OpenCode auth")
        }

        if let expiresAt = credential.expiresAt, expiresAt <= Date() {
            logger.error("xAI SuperGrok OAuth token expired")
            throw ProviderError.authenticationFailed(
                "xAI OAuth token expired; use xAI through OpenCode to refresh or reconnect it"
            )
        }

        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("grok-build", forHTTPHeaderField: "x-grok-client-surface")
        request.setValue("1.0.0", forHTTPHeaderField: "x-grok-client-version")
        request.timeoutInterval = fetchTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("xAI SuperGrok network failure: \(error.localizedDescription, privacy: .public)")
            throw ProviderError.networkError("xAI billing request failed")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        switch httpResponse.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ProviderError.authenticationFailed(
                "xAI billing endpoint returned HTTP \(httpResponse.statusCode)"
            )
        default:
            throw ProviderError.networkError(
                "xAI billing endpoint returned HTTP \(httpResponse.statusCode)"
            )
        }

        let billing: XaiBillingResponse
        do {
            billing = try JSONDecoder().decode(XaiBillingResponse.self, from: data)
        } catch {
            logger.error("xAI SuperGrok decode failure: \(error.localizedDescription, privacy: .public)")
            throw ProviderError.decodingError("Malformed xAI billing response")
        }

        guard let config = billing.config else {
            throw ProviderError.decodingError("Missing xAI billing config")
        }

        let hasPeriod = config.currentPeriod != nil
        let hasUsageField = config.creditUsagePercent != nil
        // Protobuf-JSON may omit zero-valued creditUsagePercent. A present period
        // with an absent usage field means 0% used. No period and no usage is an error.
        guard hasPeriod || hasUsageField else {
            throw ProviderError.decodingError("Missing xAI quota period and usage")
        }

        let rawUsed = config.creditUsagePercent ?? 0
        guard rawUsed.isFinite else {
            throw ProviderError.decodingError("Invalid xAI creditUsagePercent")
        }
        let usedPercent = min(max(rawUsed, 0), 100)
        let remainingPercent = max(0, 100 - usedPercent)

        let periodType = (config.currentPeriod?.type ?? "").uppercased()
        let resetDate = Self.parseISO8601Date(config.currentPeriod?.end)
            ?? Self.parseISO8601Date(config.billingPeriodEnd)

        let usage = ProviderUsage.quotaBased(
            remaining: Int(remainingPercent.rounded()),
            entitlement: 100,
            overagePermitted: false
        )

        let authSource = tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        let details: DetailedUsage
        switch periodType {
        case "USAGE_PERIOD_TYPE_MONTHLY":
            details = DetailedUsage(
                monthlyUsage: usedPercent,
                primaryReset: resetDate,
                authSource: authSource
            )
        case "USAGE_PERIOD_TYPE_DAILY":
            details = DetailedUsage(
                dailyUsage: usedPercent,
                primaryReset: resetDate,
                authSource: authSource
            )
        case "USAGE_PERIOD_TYPE_WEEKLY", "":
            // Default / unknown period types map to the observed SuperGrok weekly window.
            details = DetailedUsage(
                sevenDayUsage: usedPercent,
                sevenDayReset: resetDate,
                authSource: authSource
            )
        default:
            details = DetailedUsage(
                sevenDayUsage: usedPercent,
                sevenDayReset: resetDate,
                authSource: authSource
            )
        }

        logger.info(
            "xAI SuperGrok fetch complete: period=\(periodType, privacy: .public) used=\(usedPercent, privacy: .public)"
        )
        return ProviderResult(usage: usage, details: details)
    }

    private static func userAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "OpenCode-Bar/\(version ?? "1.0")"
    }

    static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }

        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: value)
    }

    /// Maps API period type tokens to menu window labels.
    static func periodLabel(forPeriodType periodType: String?) -> String {
        switch (periodType ?? "").uppercased() {
        case "USAGE_PERIOD_TYPE_MONTHLY":
            return "Monthly"
        case "USAGE_PERIOD_TYPE_DAILY":
            return "Daily"
        case "USAGE_PERIOD_TYPE_WEEKLY":
            return "Weekly"
        default:
            return "Weekly"
        }
    }
}
