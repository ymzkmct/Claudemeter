import XCTest
@testable import Claudemeter

final class CredentialsJSONTests: XCTestCase {
    private let original = """
    {"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh","expiresAt":1759300041852,
     "refreshTokenExpiresAt":1761675489852,"scopes":["user:inference","user:profile"],
     "subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},
     "mcpOAuth":{"some-server":{"token":"keep-me"}}}
    """

    func testParse() throws {
        let creds = try CredentialsJSON.parse(Data(original.utf8))
        XCTAssertEqual(creds.accessToken, "old-access")
        XCTAssertEqual(creds.refreshToken, "old-refresh")
        XCTAssertEqual(creds.expiresAt?.timeIntervalSince1970 ?? 0, 1_759_300_041.852, accuracy: 0.001)
        XCTAssertEqual(creds.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(creds.planLabel, "Max 20x")
        XCTAssertTrue(creds.isExpired(at: Date(timeIntervalSince1970: 1_760_000_000)))
        XCTAssertFalse(creds.isExpired(at: Date(timeIntervalSince1970: 1_759_000_000)))
        XCTAssertFalse(creds.isRefreshTokenExpired(at: Date(timeIntervalSince1970: 1_760_000_000)))
    }

    func testPlanLabelFallsBackToSubscriptionType() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"a","subscriptionType":"pro"}}"#
        XCTAssertEqual(try CredentialsJSON.parse(Data(json.utf8)).planLabel, "Pro")
    }

    func testMergePreservesUnrelatedKeys() throws {
        let expires = Date(timeIntervalSince1970: 1_760_100_000.5)
        let merged = try CredentialsJSON.merge(
            into: Data(original.utf8), accessToken: "new-access", refreshToken: "new-refresh", expiresAt: expires)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["expiresAt"] as? Int64, 1_760_100_000_500)
        XCTAssertNil(oauth["refreshTokenExpiresAt"]) // rotated refresh token: old expiry no longer applies
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:inference", "user:profile"])
        let mcp = try XCTUnwrap(root["mcpOAuth"] as? [String: Any])
        XCTAssertNotNil(mcp["some-server"])
    }

    func testMergeDropsRefreshTokenExpiryWhenTokenRotated() throws {
        let merged = try CredentialsJSON.merge(
            into: Data(original.utf8), accessToken: "a", refreshToken: "rotated", expiresAt: Date())
        let oauth = try XCTUnwrap((JSONSerialization.jsonObject(with: merged) as? [String: Any])?["claudeAiOauth"] as? [String: Any])
        XCTAssertNil(oauth["refreshTokenExpiresAt"])
        XCTAssertEqual(oauth["refreshToken"] as? String, "rotated")
    }

    func testMergeKeepsRefreshTokenExpiryWhenSameTokenReturned() throws {
        let merged = try CredentialsJSON.merge(
            into: Data(original.utf8), accessToken: "a", refreshToken: "old-refresh", expiresAt: Date())
        let creds = try CredentialsJSON.parse(merged)
        XCTAssertNotNil(creds.refreshTokenExpiresAt)
    }

    func testMergeKeepsOldRefreshTokenWhenNoneReturned() throws {
        let merged = try CredentialsJSON.merge(
            into: Data(original.utf8), accessToken: "new-access", refreshToken: nil, expiresAt: Date())
        let creds = try CredentialsJSON.parse(merged)
        XCTAssertEqual(creds.refreshToken, "old-refresh")
        XCTAssertEqual(creds.accessToken, "new-access")
    }

    func testParseRejectsMissingSection() {
        XCTAssertThrowsError(try CredentialsJSON.parse(Data(#"{"mcpOAuth":{}}"#.utf8)))
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = TokenRefresher.formBody([("refresh_token", "a+b/c=d"), ("client_id", "x")])
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "refresh_token=a%2Bb%2Fc%3Dd&client_id=x")
    }
}
