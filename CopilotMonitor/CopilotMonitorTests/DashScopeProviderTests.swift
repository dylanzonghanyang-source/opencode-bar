import XCTest
@testable import OpenCode_Bar

final class DashScopeProviderTests: XCTestCase {
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

    /// Provider with an injected fake Cookie header so tests run without
    /// browser extraction (and therefore execute in CI).
    private func makeProvider(
        statusCode: Int = 200,
        userInfoBody: String,
        balanceBody: String
    ) -> DashScopeProvider {
        let session = makeSession()
        let provider = DashScopeProvider(
            session: session,
            cookieHeader: "login_aliyunid_csrf=fake-csrf-token; login_aliyunid_ticket=fake-ticket; cna=fake-cna"
        )

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)

            if url.path.hasSuffix("/tool/user/info.json") {
                // Assert the session-token request shape.
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Cookie"),
                    "login_aliyunid_csrf=fake-csrf-token; login_aliyunid_ticket=fake-ticket; cna=fake-cna"
                )
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(userInfoBody.utf8))
            }

            // Balance RPC request: assert endpoint, method, auth headers, and
            // the sec_token query parameter.
            XCTAssertEqual(url.path, "/data/api.json")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-xsrf-token"), "fake-csrf-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-csrf-token"), "fake-csrf-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Requested-With"), "XMLHttpRequest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), providerCookieHeader)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [])
            XCTAssertEqual(query["action"], "QueryAccountBalance")
            XCTAssertEqual(query["product"], "BssOpenApi")
            XCTAssertEqual(query["sec_token"], "fake-sec-token")

            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(balanceBody.utf8))
        }
        return provider
    }

    private let providerCookieHeader =
        "login_aliyunid_csrf=fake-csrf-token; login_aliyunid_ticket=fake-ticket; cna=fake-cna"

    private let userInfoBody = #"{"code":"200","data":{"secToken":"fake-sec-token"}}"#
    private let balanceBody = """
    {
        "code": "200",
        "data": {
            "Message": "success",
            "Data": {
                "AvailableCashAmount": "50.00",
                "MybankCreditAmount": "0.00",
                "Currency": "CNY",
                "AvailableAmount": "50.00",
                "CreditAmount": "0.00",
                "QuotaLimit": "0.00"
            },
            "Code": "200",
            "Success": true
        },
        "httpStatusCode": "200",
        "successResponse": true
    }
    """

    // MARK: - Identity

    func testProviderIdentifier() {
        let provider = DashScopeProvider(cookieHeader: "x=1")
        XCTAssertEqual(provider.identifier, .dashScope)
    }

    func testProviderType() {
        let provider = DashScopeProvider(cookieHeader: "x=1")
        XCTAssertEqual(provider.type, .payAsYouGo)
    }

    // MARK: - Balance parsing

    func testFetchBalanceSuccess() async throws {
        let provider = makeProvider(userInfoBody: userInfoBody, balanceBody: balanceBody)
        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.creditsBalance ?? -1, 50.00, accuracy: 0.001)
        XCTAssertEqual(result.details?.balanceCurrency, "CNY")
        // Balance must not count toward aggregate spend.
        if case .payAsYouGo(_, let cost, _) = result.usage {
            XCTAssertNil(cost)
        } else {
            XCTFail("Expected payAsYouGo usage")
        }
    }

    func testFetchBalanceRendersBalanceRow() async throws {
        let provider = makeProvider(userInfoBody: userInfoBody, balanceBody: balanceBody)
        let result = try await provider.fetch()
        let details = try XCTUnwrap(result.details)
        let rows = ProviderMenuBuilder.dashScopeBalanceRows(details: details)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Account Balance")
        XCTAssertEqual(rows[0].value, 50.00, accuracy: 0.001)
    }

    // MARK: - Error paths

    func testMissingSecTokenThrowsAuthentication() async {
        let provider = makeProvider(
            userInfoBody: #"{"code":"200","data":{}}"#,
            balanceBody: balanceBody
        )
        do {
            _ = try await provider.fetch()
            XCTFail("Expected authenticationFailed error")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testMissingBalanceThrowsDecoding() async {
        let provider = makeProvider(
            userInfoBody: userInfoBody,
            balanceBody: #"{"code":"200","data":{"Data":{"Currency":"CNY"}}}"#
        )
        do {
            _ = try await provider.fetch()
            XCTFail("Expected decodingError error")
        } catch let error as ProviderError {
            guard case .decodingError = error else {
                return XCTFail("Expected decodingError, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testHTTP401ThrowsAuthentication() async {
        let provider = makeProvider(
            statusCode: 401,
            userInfoBody: userInfoBody,
            balanceBody: "{}"
        )
        do {
            _ = try await provider.fetch()
            XCTFail("Expected authenticationFailed error")
        } catch let error as ProviderError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Cookie header parsing

    func testExtractCookieValue() {
        let header = "a=1; login_aliyunid_csrf=abc; b=2"
        XCTAssertEqual(DashScopeProvider.extractCookieValue(name: "login_aliyunid_csrf", from: header), "abc")
        XCTAssertNil(DashScopeProvider.extractCookieValue(name: "missing", from: header))
    }
}
