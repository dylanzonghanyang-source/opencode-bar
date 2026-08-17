import XCTest
@testable import OpenCode_Bar

final class TimiccProviderTests: XCTestCase {
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

    // MARK: - Identity

    func testProviderIdentifier() {
        let provider = TimiccProvider()
        XCTAssertEqual(provider.identifier, .timicc)
    }

    func testProviderType() {
        let provider = TimiccProvider()
        XCTAssertEqual(provider.type, .payAsYouGo)
    }

    // MARK: - Response decoding

    /// Real /v1/usage response shape (USD balance + daily/model usage).
    private let usageJSON = """
    {
      "balance": 53.46212396,
      "daily_usage": [
        {
          "date": "2026-08-13",
          "requests": 112,
          "input_tokens": 752688,
          "output_tokens": 99112,
          "cache_read_tokens": 9982464,
          "cache_write_tokens": 0,
          "total_tokens": 10834264,
          "cost": 7.09128,
          "actual_cost": 1.418256
        }
      ],
      "isValid": true,
      "mode": "unrestricted",
      "model_stats": [
        {
          "model": "grok-4.5",
          "requests": 1277,
          "input_tokens": 11884005,
          "output_tokens": 889075,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 112028401,
          "total_tokens": 124801481,
          "cost": 85.1166605
        }
      ],
      "planName": "钱包余额",
      "remaining": 53.46212396,
      "unit": "USD",
      "usage": {
        "average_duration_ms": 16138.63,
        "rpm": 0,
        "today": {
          "actual_cost": 0,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 0,
          "cost": 0,
          "input_tokens": 0,
          "output_tokens": 0,
          "requests": 0,
          "total_tokens": 0
        },
        "total": {
          "actual_cost": 9.22079405,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 0,
          "cost": 0,
          "input_tokens": 0,
          "output_tokens": 0,
          "requests": 0,
          "total_tokens": 0
        }
      }
    }
    """

    func testUsageResponseDecodesAllFields() throws {
        let response = try JSONDecoder().decode(
            TimiccProvider.UsageResponse.self,
            from: usageJSON.data(using: .utf8)!
        )
        XCTAssertEqual(response.balance, 53.46212396)
        XCTAssertEqual(response.remaining, 53.46212396)
        XCTAssertEqual(response.unit, "USD")
        XCTAssertEqual(response.planName, "钱包余额")
        XCTAssertEqual(response.isValid, true)
        XCTAssertEqual(response.mode, "unrestricted")

        let day = try XCTUnwrap(response.dailyUsage?.first)
        XCTAssertEqual(day.date, "2026-08-13")
        XCTAssertEqual(day.requests, 112)
        XCTAssertEqual(day.cost, 7.09128)
        XCTAssertEqual(day.actualCost, 1.418256)

        let model = try XCTUnwrap(response.modelStats?.first)
        XCTAssertEqual(model.model, "grok-4.5")
        XCTAssertEqual(model.requests, 1277)

        XCTAssertEqual(response.usage?.today?.requests, 0)
        XCTAssertEqual(response.usage?.total?.actualCost, 9.22079405)
    }

    // MARK: - Fetch

    func testFetchSuccessReturnsBalanceAsPayAsYouGoCost() async throws {
        guard TokenManager.shared.getTimiccAPIKey() != nil else {
            throw XCTSkip("TIMICC API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = TimiccProvider(tokenManager: .shared, session: session)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(self.usageJSON.utf8))
        }

        let result = try await provider.fetch()

        guard case .payAsYouGo(let utilization, let cost, _) = result.usage else {
            return XCTFail("Expected payAsYouGo usage")
        }
        XCTAssertEqual(utilization, 0)
        // Balance is not spend: cost must stay nil so the aggregate total is unaffected.
        XCTAssertNil(cost)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 53.46212396)
        XCTAssertEqual(details.balanceCurrency, "USD")
        XCTAssertEqual(details.balanceCurrencySymbol, "$")
    }

    /// The unified two-column metric row must render TIMICC balance as
    /// "Balance: $53.46 left" and skip zero granted/topped-up rows.
    @MainActor
    func testTimiccPayAsYouGoMetricRows() {
        let details = DetailedUsage(
            creditsBalance: 53.46212396,
            balanceCurrency: "USD"
        )
        let rows = MenuQuotaWindowBuilder.payAsYouGoMetricRows(
            creditsBalance: details.creditsBalance,
            creditsRemaining: nil,
            cost: nil,
            currencySymbol: details.balanceCurrencySymbol,
            balanceGranted: details.balanceGranted,
            balanceToppedUp: details.balanceToppedUp
        )
        XCTAssertEqual(rows.map(\.label), ["Balance"])
        XCTAssertEqual(rows[0].value, "$53.46 left")
    }

    func testFetchPropagatesHTTPError() async throws {
        guard TokenManager.shared.getTimiccAPIKey() != nil else {
            throw XCTSkip("TIMICC API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = TimiccProvider(tokenManager: .shared, session: session)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected network error for 401")
        } catch let error as ProviderError {
            guard case .networkError = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
        }
    }
}
