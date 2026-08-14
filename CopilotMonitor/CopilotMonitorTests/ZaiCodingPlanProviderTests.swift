import XCTest
@testable import OpenCode_Bar

final class ZaiCodingPlanProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.identifier, .zaiCodingPlan)
    }

    func testProviderType() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    // MARK: - Helpers

    /// Real Lite-tier response shape: only CREDIT_LIMIT items, two rolling windows
    /// (unit=3 -> 5-hour session, unit=6 -> 7-day weekly), usage/remaining instead
    /// of total, no TOKENS_LIMIT / TIME_LIMIT.
    private let creditOnlyJSON = """
    {
      "data": {
        "limits": [
          {
            "type": "CREDIT_LIMIT",
            "unit": 3,
            "number": 5,
            "usage": 2000,
            "currentValue": 27,
            "remaining": 1972,
            "percentage": 1,
            "nextResetTime": 1786717056698
          },
          {
            "type": "CREDIT_LIMIT",
            "unit": 6,
            "number": 1,
            "usage": 10000,
            "currentValue": 27,
            "remaining": 9972,
            "percentage": 1,
            "nextResetTime": 1787301777997
          }
        ],
        "level": "lite"
      }
    }
    """

    private let modelUsageJSON = """
    {"data": {"totalUsage": {"totalTokensUsage": 120, "totalModelCallCount": 8}}}
    """

    private let toolUsageJSON = """
    {"data": {"totalUsage": {"totalNetworkSearchCount": 1, "totalWebReadMcpCount": 2, "totalZreadMcpCount": 3}}}
    """

    /// Installs a mock session that serves quota/model/tool endpoints and runs
    /// the real `fetch()` pipeline with an injected API key (no credential store).
    private func makeProvider(quotaJSON: String) -> ZaiCodingPlanProvider {
        let session = makeSession()
        let provider = ZaiCodingPlanProvider(tokenManager: .shared, session: session, apiKey: "sk-test-fake")

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body: String
            if url.path.contains("quota/limit") {
                body = quotaJSON
            } else if url.path.contains("model-usage") {
                body = self.modelUsageJSON
            } else if url.path.contains("tool-usage") {
                body = self.toolUsageJSON
            } else {
                body = "{}"
            }
            return (response, Data(body.utf8))
        }
        return provider
    }

    // MARK: - CREDIT_LIMIT-only (lite tier)

    /// Provider-level regression: a CREDIT_LIMIT-only response with BOTH windows
    /// must surface the 5-hour window as token usage AND the weekly window via
    /// the weekly fields — not drop the second window.
    func testCreditOnlyResponsePopulatesBothWindows() async throws {
        let result = try await makeProvider(quotaJSON: creditOnlyJSON).fetch()
        let details = try XCTUnwrap(result.details)

        // 5-hour session window (unit=3, usage=2000)
        XCTAssertEqual(details.tokenUsagePercent, 1)
        XCTAssertEqual(details.tokenUsageUsed, 27)
        XCTAssertEqual(details.tokenUsageTotal, 2000)
        XCTAssertNotNil(details.tokenUsageReset)

        // Weekly window (unit=6, usage=10000)
        XCTAssertEqual(details.weeklyUsagePercent, 1)
        XCTAssertEqual(details.weeklyUsageUsed, 27)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
        XCTAssertNotNil(details.weeklyUsageReset)

        // No MCP window in this schema
        XCTAssertNil(details.mcpUsagePercent)

        // Model/tool usage still fetched
        XCTAssertEqual(details.modelUsageTokens, 120)
        XCTAssertEqual(details.toolNetworkSearchCount, 1)
    }

    func testCreditOnlySingleWindowStillRenders() async throws {
        // A response with only the weekly window (no unit=3 item) must map it
        // to the weekly fields and NOT double-fill the session/token fields.
        let singleWindow = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 10000,
           "currentValue": 27, "remaining": 9972, "percentage": 1,
           "nextResetTime": 1787301777997}
        ], "level": "lite"}}
        """
        let result = try await makeProvider(quotaJSON: singleWindow).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertNil(details.tokenUsageTotal)
        XCTAssertNil(details.tokenUsageUsed)
        XCTAssertEqual(details.weeklyUsageTotal, 10000)
        XCTAssertEqual(details.weeklyUsageUsed, 27)
    }

    // MARK: - Standard schema (unchanged behavior)

    /// Old TOKENS_LIMIT / TIME_LIMIT schema must keep working exactly as before
    /// and must NOT pick up any CREDIT_LIMIT fallback when token windows exist.
    func testStandardSchemaUnchanged() async throws {
        let standardJSON = """
        {"data": {"limits": [
          {"type": "TOKENS_LIMIT", "total": 5000, "currentValue": 100, "percentage": 2,
           "nextResetTime": 1786717056698},
          {"type": "TIME_LIMIT", "total": 300, "currentValue": 12, "percentage": 4,
           "nextResetTime": 1787400000000}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: standardJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.tokenUsagePercent, 2)
        XCTAssertEqual(details.tokenUsageUsed, 100)
        XCTAssertEqual(details.tokenUsageTotal, 5000)
        XCTAssertEqual(details.mcpUsagePercent, 4)
        XCTAssertEqual(details.mcpUsageUsed, 12)
        XCTAssertEqual(details.mcpUsageTotal, 300)
        // Weekly fields are only for the CREDIT_LIMIT-only path.
        XCTAssertNil(details.weeklyUsagePercent)
        XCTAssertNil(details.weeklyUsageTotal)
    }

    /// Mixed response: TOKENS_LIMIT present must win over CREDIT_LIMIT items,
    /// and the credit weekly window must not be populated.
    func testMixedSchemaPrefersTokenWindows() async throws {
        let mixedJSON = """
        {"data": {"limits": [
          {"type": "CREDIT_LIMIT", "unit": 3, "usage": 2000, "currentValue": 27, "percentage": 1},
          {"type": "CREDIT_LIMIT", "unit": 6, "usage": 10000, "currentValue": 27, "percentage": 1},
          {"type": "TOKENS_LIMIT", "total": 5000, "currentValue": 100, "percentage": 2}
        ]}}
        """
        let result = try await makeProvider(quotaJSON: mixedJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.tokenUsageTotal, 5000)
        XCTAssertEqual(details.tokenUsagePercent, 2)
        XCTAssertNil(details.weeklyUsagePercent)
        XCTAssertNil(details.weeklyUsageTotal)
    }

    // MARK: - Decoding

    func testCreditLimitItemsDecode() throws {
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: creditOnlyJSON.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        XCTAssertEqual(limits.count, 2)

        let session = limits[0]
        XCTAssertEqual(session.type, "CREDIT_LIMIT")
        XCTAssertEqual(session.unit, 3)
        XCTAssertEqual(session.number, 5)
        XCTAssertEqual(session.usage, 2000)
        XCTAssertEqual(session.remaining, 1972)
        XCTAssertEqual(session.currentValue, 27)
        XCTAssertEqual(session.percentage, 1)
        XCTAssertNotNil(session.nextResetTime)
        XCTAssertNil(session.total)

        let weekly = limits[1]
        XCTAssertEqual(weekly.unit, 6)
        XCTAssertEqual(weekly.number, 1)
        XCTAssertEqual(weekly.usage, 10000)
        XCTAssertEqual(weekly.remaining, 9972)
    }

    func testCreditLimitResolvedTotalFallsBackToUsage() throws {
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: creditOnlyJSON.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        // CREDIT_LIMIT has no `total`; resolvedTotal must fall back to `usage`.
        XCTAssertNil(limits[0].total)
        XCTAssertEqual(limits[0].resolvedTotal, 2000)
    }

    func testCreditLimitComputedPercentageFallsBackToCurrentValueOverUsage() throws {
        // Strip `percentage` to exercise the derivation fallback: 27/2000*100 = 1.35
        let stripped = creditOnlyJSON.replacingOccurrences(of: "\"percentage\": 1,", with: "")
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: stripped.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        let computed = try XCTUnwrap(limits[0].computedPercentage)
        XCTAssertEqual(computed, 1.35, accuracy: 0.001)
    }
}
