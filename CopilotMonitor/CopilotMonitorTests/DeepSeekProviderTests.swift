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
    }

    // MARK: - Fetch

    func testFetchSuccessReturnsBalanceAsPayAsYouGoCost() async throws {
        guard TokenManager.shared.getDeepSeekAPIKey() != nil else {
            throw XCTSkip("DeepSeek API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = DeepSeekProvider(tokenManager: .shared, session: session)

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(self.balanceJSON.utf8))
        }

        let result = try await provider.fetch()

        guard case .payAsYouGo(let utilization, let cost, _) = result.usage else {
            return XCTFail("Expected payAsYouGo usage")
        }
        XCTAssertEqual(utilization, 0)
        XCTAssertEqual(cost, 103.49)

        let details = try XCTUnwrap(result.details)
        XCTAssertEqual(details.creditsBalance, 103.49)
        XCTAssertEqual(details.balanceCurrency, "CNY")
        XCTAssertEqual(details.balanceGranted, 0.0)
        XCTAssertEqual(details.balanceToppedUp, 103.49)
    }

    func testFetchPropagatesHTTPError() async throws {
        guard TokenManager.shared.getDeepSeekAPIKey() != nil else {
            throw XCTSkip("DeepSeek API key not available; skipping fetch test.")
        }

        let session = makeSession()
        let provider = DeepSeekProvider(tokenManager: .shared, session: session)

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
