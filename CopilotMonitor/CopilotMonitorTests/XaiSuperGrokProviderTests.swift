import XCTest
@testable import OpenCode_Bar

final class XaiSuperGrokProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        static var requestCount = 0

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            MockURLProtocol.requestCount += 1
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

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
        super.tearDown()
    }

    private func futureExpiresMs(offsetSeconds: TimeInterval = 3600) -> Int64 {
        Int64((Date().addingTimeInterval(offsetSeconds).timeIntervalSince1970) * 1000)
    }

    private func pastExpiresMs(offsetSeconds: TimeInterval = 3600) -> Int64 {
        Int64((Date().addingTimeInterval(-offsetSeconds).timeIntervalSince1970) * 1000)
    }

    private func weeklyFixture(usedPercent: Double? = 5, includeUsageField: Bool = true) -> String {
        var usageLine = ""
        if includeUsageField, let usedPercent {
            usageLine = "\"creditUsagePercent\": \(usedPercent),"
        }
        return """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-07-13T02:24:00.983423+00:00",
              "end": "2026-07-20T02:24:00.983423+00:00"
            },
            \(usageLine)
            "isUnifiedBillingUser": true,
            "productUsage": [
              { "product": "Api", "usagePercent": 5 },
              { "product": "GrokChat" }
            ]
          }
        }
        """
    }

    private func makeProvider(
        accessToken: String = "fake-token",
        expiresAt: Date? = Date().addingTimeInterval(3600),
        statusCode: Int = 200,
        body: String
    ) -> XaiSuperGrokProvider {
        let session = makeSession()
        let provider = XaiSuperGrokProvider(
            session: session,
            credential: XaiOAuthCredential(accessToken: accessToken, expiresAt: expiresAt)
        )

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                url.absoluteString,
                "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(accessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-grok-client-surface"), "grok-build")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-grok-client-version"), "1.0.0")
            // Never allow logging/asserting real secrets beyond the injected fake token.
            XCTAssertFalse((request.value(forHTTPHeaderField: "Authorization") ?? "").contains("eyJ"))

            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        return provider
    }

    // MARK: - Auth decoding

    func testOpenCodeAuthDecodesXaiOAuthOnly() throws {
        let expires = futureExpiresMs()
        let json = """
        {
          "xai": {
            "type": "oauth",
            "access": "fake-token",
            "refresh": "fake-refresh",
            "expires": \(expires)
          }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)
        XCTAssertEqual(auth.xai?.type, "oauth")
        XCTAssertEqual(auth.xai?.access, "fake-token")
        XCTAssertEqual(auth.xai?.refresh, "fake-refresh")
        XCTAssertEqual(auth.xai?.expires, expires)
    }

    // MARK: - Provider identity

    func testProviderIdentifierAndType() {
        let provider = XaiSuperGrokProvider()
        XCTAssertEqual(provider.identifier, .xaiSuperGrok)
        XCTAssertEqual(provider.type, .quotaBased)
        XCTAssertEqual(ProviderIdentifier.xaiSuperGrok.displayName, "xAI SuperGrok")
        XCTAssertEqual(ProviderIdentifier.xaiSuperGrok.shortDisplayName, "SuperGrok")
        XCTAssertEqual(ProviderIdentifier.xaiSuperGrok.rawValue, "xai_supergrok")
    }

    // MARK: - Fetch mapping

    func testWeeklyFivePercentFixture() async throws {
        let result = try await makeProvider(body: weeklyFixture(usedPercent: 5)).fetch()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        guard case let .quotaBased(remaining, entitlement, overage) = result.usage else {
            return XCTFail("expected quotaBased usage")
        }
        XCTAssertEqual(entitlement, 100)
        XCTAssertFalse(overage)
        XCTAssertEqual(remaining, 95)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.sevenDayUsage, 5)
        XCTAssertNotNil(details.sevenDayReset)
        XCTAssertNil(details.monthlyUsage)
        XCTAssertNil(details.dailyUsage)

        let windows = MenuQuotaWindowBuilder.windows(
            for: .xaiSuperGrok,
            primaryUsage: result.usage.usagePercentage,
            details: details
        )
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertEqual(windows[0].usedPercent, 5)

        let rows = MenuQuotaWindowBuilder.quotaMetricRows(
            for: .xaiSuperGrok,
            primaryUsage: result.usage.usagePercentage,
            details: details
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Weekly")
        XCTAssertEqual(rows[0].value, "5% used")
    }

    func testZeroValueOmissionMeansZeroUsed() async throws {
        let result = try await makeProvider(body: weeklyFixture(includeUsageField: false)).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.sevenDayUsage, 0)

        guard case let .quotaBased(remaining, _, _) = result.usage else {
            return XCTFail("expected quotaBased usage")
        }
        XCTAssertEqual(remaining, 100)
    }

    func testFractionalISOResetParses() async throws {
        let result = try await makeProvider(body: weeklyFixture(usedPercent: 5)).fetch()
        let reset = try XCTUnwrap(result.details?.sevenDayReset)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2026-07-20T02:24:00.983423+00:00"))
        XCTAssertEqual(reset.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testExpiredTokenDoesNotNetwork() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("expired token must not hit network")
            throw URLError(.notConnectedToInternet)
        }

        let provider = XaiSuperGrokProvider(
            session: makeSession(),
            credential: XaiOAuthCredential(
                accessToken: "fake-token",
                expiresAt: Date().addingTimeInterval(-60)
            )
        )

        do {
            _ = try await provider.fetch()
            XCTFail("expected authentication failure")
        } catch let error as ProviderError {
            guard case let .authenticationFailed(message) = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
            XCTAssertTrue(message.lowercased().contains("expired"))
            XCTAssertEqual(MockURLProtocol.requestCount, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingCredentialFailsWithoutNetwork() async {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("missing credential must not hit network")
            throw URLError(.notConnectedToInternet)
        }

        // No override and no real xai auth on this machine → authentication failure.
        let provider = XaiSuperGrokProvider(session: makeSession())
        do {
            _ = try await provider.fetch()
            XCTFail("expected authentication failure")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else {
                return XCTFail("expected authenticationFailed, got \(error)")
            }
            XCTAssertEqual(MockURLProtocol.requestCount, 0)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTP401ProducesAuthErrorWithoutLeakingToken() async {
        do {
            _ = try await makeProvider(statusCode: 401, body: #"{"error":"nope"}"#).fetch()
            XCTFail("expected failure")
        } catch let error as ProviderError {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("401"))
            XCTAssertFalse(description.contains("fake-token"))
            XCTAssertFalse(description.lowercased().contains("bearer"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testHTTP500ProducesNetworkError() async {
        do {
            _ = try await makeProvider(statusCode: 500, body: "server").fetch()
            XCTFail("expected failure")
        } catch let error as ProviderError {
            guard case let .networkError(message) = error else {
                return XCTFail("expected networkError, got \(error)")
            }
            XCTAssertTrue(message.contains("500"))
            XCTAssertFalse(message.contains("fake-token"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMalformedQuotaResponse() async {
        let body = #"{"config":{"isUnifiedBillingUser":true}}"#
        do {
            _ = try await makeProvider(body: body).fetch()
            XCTFail("expected decoding error")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMonthlyPeriodMapsToMonthlyUsage() async throws {
        let body = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_MONTHLY",
              "end": "2026-08-01T00:00:00Z"
            },
            "creditUsagePercent": 12
          }
        }
        """
        let result = try await makeProvider(body: body).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.monthlyUsage, 12)
        XCTAssertNil(details.sevenDayUsage)
        let rows = MenuQuotaWindowBuilder.quotaMetricRows(
            for: .xaiSuperGrok,
            primaryUsage: result.usage.usagePercentage,
            details: details
        )
        XCTAssertEqual(rows.first?.label, "Monthly")
        XCTAssertEqual(rows.first?.value, "12% used")
    }

    // MARK: - Menu hierarchy / status-bar candidates

    func testMenuHierarchyParentHasNoPercent() {
        let details = DetailedUsage(sevenDayUsage: 5, sevenDayReset: Date())
        let rows = MenuQuotaWindowBuilder.quotaMetricRows(
            for: .xaiSuperGrok,
            primaryUsage: 5,
            details: details
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Weekly")
        XCTAssertEqual(rows[0].value, "5% used")

        // Parent display name must stay metric-free.
        let parent = ProviderIdentifier.xaiSuperGrok.displayName
        XCTAssertFalse(parent.contains("%"))
        XCTAssertFalse(parent.lowercased().contains("used"))
    }

    @MainActor
    func testUsagePercentCandidatesPreferWeekly() {
        let details = DetailedUsage(sevenDayUsage: 5)
        let usage = ProviderUsage.quotaBased(remaining: 95, entitlement: 100, overagePermitted: false)
        let candidates = StatusBarController.usagePercentCandidates(
            identifier: .xaiSuperGrok,
            usage: usage,
            details: details
        )
        XCTAssertTrue(candidates.contains { $0.priority == .weekly && $0.percent == 5 })
    }

    // MARK: - Private provider regression anchors

    func testPrivatePayGoOrderStillHidesZenAndKeepsBalances() {
        XCTAssertEqual(
            MainMenuProviderPresentation.payAsYouGoOrder,
            [.deepSeek, .dashScope, .timicc, .openRouter]
        )
        XCTAssertFalse(MainMenuProviderPresentation.payAsYouGoOrder.contains(.openCodeZen))
        XCTAssertFalse(MainMenuProviderPresentation.payAsYouGoOrder.contains(.xaiSuperGrok))

        let deepSeekRows = MenuQuotaWindowBuilder.payAsYouGoMetricRows(
            creditsBalance: 12.34,
            creditsRemaining: nil,
            cost: nil,
            currencySymbol: "¥"
        )
        XCTAssertEqual(deepSeekRows.first?.label, "Balance")
        XCTAssertTrue(deepSeekRows.first?.value.contains("left") == true)

        let dashRows = MenuQuotaWindowBuilder.payAsYouGoMetricRows(
            creditsBalance: 50,
            creditsRemaining: nil,
            cost: nil,
            currencySymbol: "¥"
        )
        XCTAssertEqual(dashRows.first?.value, "¥50.00 left")

        let timiccRows = MenuQuotaWindowBuilder.payAsYouGoMetricRows(
            creditsBalance: 88.88,
            creditsRemaining: nil,
            cost: nil,
            currencySymbol: "$"
        )
        XCTAssertEqual(timiccRows.first?.label, "Balance")
        XCTAssertTrue(timiccRows.first?.value.contains("left") == true)
    }

    func testErrorOnlyProviderStillHidden() {
        let hidden = MainMenuProviderPresentation.shouldHideErrorOnlyProvider(
            identifier: .antigravity,
            result: nil,
            errorMessage: "boom",
            isLoading: false
        )
        XCTAssertTrue(hidden)
    }

    func testExistingGrokIdentifierRemainsDistinct() {
        XCTAssertNotEqual(ProviderIdentifier.grok, ProviderIdentifier.xaiSuperGrok)
        XCTAssertEqual(ProviderIdentifier.grok.displayName, "Grok")
        XCTAssertEqual(ProviderIdentifier.xaiSuperGrok.displayName, "xAI SuperGrok")
    }
}
