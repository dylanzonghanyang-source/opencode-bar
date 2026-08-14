import XCTest
@testable import OpenCode_Bar

final class DeepSeekProviderTests: XCTestCase {
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

    /// Provider with an injected fake API key so tests run without the
    /// credential store (and therefore execute in CI).
    private func makeProvider(statusCode: Int = 200, body: String) -> DeepSeekProvider {
        let session = makeSession()
        let provider = DeepSeekProvider(tokenManager: .shared, session: session, apiKey: "sk-test-fake")

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(body.utf8))
        }
        return provider
    }

    // MARK: - Identity

    func testProviderIdentifier() {
        let provider = DeepSeekProvider()
        XCTAssertEqual(provider.identifier, .deepSeek)
    }

    func testProviderType() {
        let provider = DeepSeekProvider()
        XCTAssertEqual(provider.type, .payAsYouGo)
    }

    // MARK: - Response decoding

    /// Real /user/balance response shape (string amounts, CNY).
    private let balanceJSON = """
    {
      "is_available": true,
      "balance_infos": [
        {
          "currency": "CNY",
          "total_balance": "103.49",
          "granted_balance": "0.00",
          "topped_up_balance": "103.49"
        }
      ]
    }
    """

    func testBalanceResponseDecodesStringAmounts() throws {
        let response = try JSONDecoder().decode(
            DeepSeekProvider.BalanceResponse.self,
            from: balanceJSON.data(using: .utf8)!
        )
        let info = try XCTUnwrap(response.balanceInfos?.first)
        XCTAssertEqual(info.currency, "CNY")
        XCTAssertEqual(info.totalBalance, "103.49")
        XCTAssertEqual(info.grantedBalance, "0.00")
        XCTAssertEqual(info.toppedUpBalance, "103.49")
        XCTAssertEqual(response.isAvailable, true)
    }

    // MARK: - Fetch

    func testFetchSuccessSurfacesBalanceInDetails() async throws {
        let result = try await makeProvider(body: balanceJSON).fetch()

        guard case .payAsYouGo(let utilization, let cost, _) = result.usage else {
            return XCTFail("Expected payAsYouGo usage")
        }
        XCTAssertEqual(utilization, 0)
        // Balance is not spend: cost must stay nil so the aggregate total is unaffected.
        XCTAssertNil(cost)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 103.49)
        XCTAssertEqual(details.balanceCurrency, "CNY")
        XCTAssertEqual(details.balanceCurrencySymbol, "¥")
        XCTAssertEqual(details.balanceGranted, 0.0)
        XCTAssertEqual(details.balanceToppedUp, 103.49)
    }

    func testFetchUnavailableBalanceStillReturnsData() async throws {
        // is_available=false is a diagnostic signal; balance_infos may still be
        // present (zeroed/frozen) and should still be rendered.
        let unavailableJSON = """
        {
          "is_available": false,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "0.00", "granted_balance": "0.00", "topped_up_balance": "0.00"}
          ]
        }
        """
        let result = try await makeProvider(body: unavailableJSON).fetch()
        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 0.0)
        XCTAssertEqual(details.balanceCurrency, "CNY")
    }

    func testFetchUnparseableTotalBalanceThrowsDecodingError() async throws {
        let badJSON = """
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "not-a-number", "granted_balance": "0.00", "topped_up_balance": "0.00"}
          ]
        }
        """
        do {
            _ = try await makeProvider(body: badJSON).fetch()
            XCTFail("Expected decodingError for unparseable total_balance")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        }
    }

    func testFetchPropagatesHTTPError() async throws {
        do {
            _ = try await makeProvider(statusCode: 401, body: "").fetch()
            XCTFail("Expected network error for 401")
        } catch let error as ProviderError {
            guard case .networkError = error else {
                return XCTFail("Expected networkError, got \(error)")
            }
        }
    }
}
