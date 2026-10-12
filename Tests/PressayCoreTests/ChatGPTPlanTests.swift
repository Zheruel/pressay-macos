import Foundation
import XCTest
@testable import PressayCore

final class ChatGPTPlanTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testFirstSignInRegistersWithAgentNameAndPKCE() {
        let attempt = ChatGPTAuthAttempt(redirectURI: "http://127.0.0.1:1455/auth/callback", clientID: nil)
        let url = attempt.authorizeURL(hostID: "urn:uuid:abc", idTokenHint: "token", loginHint: "a@b.c")
        let q = query(url)
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Pressay")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], attempt.challenge)
        XCTAssertEqual(q["scope"], ChatGPTPlan.scopes)
        XCTAssertNil(q["id_token_hint"], "hints belong to returning sign-ins only")
    }

    func testReturningSignInReusesClientAndEncodesPlus() {
        let attempt = ChatGPTAuthAttempt(redirectURI: "http://127.0.0.1:1455/auth/callback", clientID: "oaiapp_1")
        let url = attempt.authorizeURL(hostID: "urn:uuid:abc", idTokenHint: nil, loginHint: "me+pressay@x.com")
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertEqual(query(url)["login_hint"], "me+pressay@x.com")
        XCTAssertEqual(query(url)["client_id"], "oaiapp_1")
        XCTAssertNil(query(url)["agent_name_hint"])
    }

    func testIDTokenClaimsAreChecked() throws {
        let good: [String: Any] = [
            "iss": ChatGPTPlan.issuer, "aud": "oaiapp_1", "nonce": "n",
            "exp": Date().addingTimeInterval(600).timeIntervalSince1970,
        ]
        XCTAssertNoThrow(try ChatGPTAuthClient.checkClaims(good, clientID: "oaiapp_1", nonce: "n"))
        var wrongNonce = good; wrongNonce["nonce"] = "x"
        XCTAssertThrowsError(try ChatGPTAuthClient.checkClaims(wrongNonce, clientID: "oaiapp_1", nonce: "n"))
        var wrongAudience = good; wrongAudience["aud"] = ["other"]
        XCTAssertThrowsError(try ChatGPTAuthClient.checkClaims(wrongAudience, clientID: "oaiapp_1", nonce: "n"))
        var expired = good; expired["exp"] = Date().addingTimeInterval(-600).timeIntervalSince1970
        XCTAssertThrowsError(try ChatGPTAuthClient.checkClaims(expired, clientID: "oaiapp_1", nonce: "n"))
    }

    func testRequestBodyOmitsFieldsPlanUsageRejects() {
        let body = ChatGPTCleaner.requestBody(
            transcript: "hello there", targetBundleID: nil, vocabulary: [],
            model: "gpt-6-luna", effort: "low"
        )
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        for unsupported in ["temperature", "max_output_tokens", "metadata", "user", "top_p"] {
            XCTAssertNil(body[unsupported], unsupported)
        }
    }

    func testStreamAccumulatesDeltasAndMapsUsageLimit() throws {
        var reader = SSEReader()
        let lines = [
            #"data: {"type":"response.output_text.delta","delta":"Hello, "}"#,
            "event: ignored",
            #"data: {"type":"response.output_text.delta","delta":"world."}"#,
        ]
        for line in lines {
            if let event = reader.feed(line) { XCTAssertNil(try ChatGPTCleaner.handle(event, into: &reader)) }
        }
        let done = try XCTUnwrap(reader.feed(#"data: {"type":"response.completed"}"#))
        XCTAssertEqual(try ChatGPTCleaner.handle(done, into: &reader), "Hello, world.")

        let limit = try XCTUnwrap(reader.feed(
            #"data: {"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}}"#
        ))
        XCTAssertThrowsError(try ChatGPTCleaner.handle(limit, into: &reader)) { error in
            guard case ChatGPTCleaner.CleanupError.usageLimit = error else { return XCTFail("\(error)") }
        }
    }
}
