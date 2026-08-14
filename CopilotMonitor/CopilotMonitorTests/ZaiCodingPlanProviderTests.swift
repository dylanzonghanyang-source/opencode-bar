import XCTest
@testable import OpenCode_Bar

final class ZaiCodingPlanProviderTests: XCTestCase {

    func testProviderIdentifier() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.identifier, .zaiCodingPlan)
    }

    func testProviderType() {
        let provider = ZaiCodingPlanProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    // MARK: - CREDIT_LIMIT (lite tier) support

    /// Mirrors the real response shape returned by api.z.ai/api/monitor/usage/quota/limit
    /// for lite/credit plans: only CREDIT_LIMIT items, with `usage`/`remaining`
    /// instead of `total`, and no TOKENS_LIMIT / TIME_LIMIT windows.
    private let creditLimitJSON = """
    {
      "code": 200,
      "msg": "Operation successful",
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
      },
      "success": true
    }
    """

    /// The API wraps the limits under `data.limits`; decode through the envelope.
    private func decodeLimits(from json: String) throws -> [ZaiQuotaLimitItem] {
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let data = json.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return try XCTUnwrap(envelope.data.limits)
    }

    func testCreditLimitItemsDecode() throws {
        let limits = try decodeLimits(from: creditLimitJSON)
        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0].type, "CREDIT_LIMIT")
        XCTAssertEqual(limits[0].usage, 2000)
        XCTAssertEqual(limits[0].remaining, 1972)
        XCTAssertEqual(limits[0].currentValue, 27)
        XCTAssertEqual(limits[0].percentage, 1)
        XCTAssertNotNil(limits[0].nextResetTime)
    }

    func testCreditLimitResolvedTotalFallsBackToUsage() throws {
        let limits = try decodeLimits(from: creditLimitJSON)
        // CREDIT_LIMIT has no `total`; resolvedTotal must fall back to `usage`.
        XCTAssertNil(limits[0].total)
        XCTAssertEqual(limits[0].resolvedTotal, 2000)
    }

    func testCreditLimitComputedPercentageUsesPercentageField() throws {
        let limits = try decodeLimits(from: creditLimitJSON)
        // `percentage` is provided by the API (1%) and must win over any derivation.
        XCTAssertEqual(limits[0].computedPercentage, 1)
    }

    func testCreditLimitComputedPercentageFallsBackToCurrentValueOverUsage() throws {
        // Strip `percentage` to exercise the derivation fallback:
        // 27 / 2000 * 100 = 1.35
        let stripped = creditLimitJSON.replacingOccurrences(
            of: "\"percentage\": 1,",
            with: ""
        )
        let limits = try decodeLimits(from: stripped)
        let computed = try XCTUnwrap(limits[0].computedPercentage)
        XCTAssertEqual(computed, 1.35, accuracy: 0.001)
    }

    func testTokenLimitPrefersTokenWindowsOverCreditItems() throws {
        // A plan that reports both TOKENS_LIMIT and CREDIT_LIMIT must keep
        // preferring the token window (existing behavior preserved).
        let mixedJSON = """
        {
          "data": {
            "limits": [
              {"type": "CREDIT_LIMIT", "usage": 2000, "currentValue": 27, "percentage": 1},
              {"type": "TOKENS_LIMIT", "total": 5000, "currentValue": 100, "percentage": 2}
            ]
          }
        }
        """
        struct Envelope: Decodable {
            let data: ZaiQuotaLimitResponse
        }
        let envelope = try JSONDecoder().decode(
            Envelope.self,
            from: mixedJSON.data(using: .utf8)!
        )
        let limits = try XCTUnwrap(envelope.data.limits)
        let tokenLimit = limits.first { $0.type.uppercased() == "TOKENS_LIMIT" }
            ?? limits.first { $0.type.uppercased() == "CREDIT_LIMIT" }
        XCTAssertEqual(tokenLimit?.type, "TOKENS_LIMIT")
        XCTAssertEqual(tokenLimit?.resolvedTotal, 5000)
    }
}
