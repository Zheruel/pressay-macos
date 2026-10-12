import Foundation
import XCTest
@testable import PressayCore

final class ClaudeCleanupTests: XCTestCase {
    func testVocabularyBlockMergesAliasesUnderOnePreferredTerm() {
        let block = ClaudeCleanupPrompt.vocabularyBlock([
            .init(preferred: "Claude Code", aliases: ["cloud code"]),
            .init(preferred: "GitHub"),
            .init(preferred: "Claude Code", aliases: ["clod code", "cloud code"]),
        ])
        XCTAssertEqual(block, "Claude Code (often misheard as: cloud code, clod code)\nGitHub")
    }

    func testRequestBodyCachesStableSystemPromptAndCarriesModelSettings() throws {
        let vocabulary = [VocabularyParser.Entry(preferred: "Telnyx", aliases: ["telnex"])]
        let body = ClaudeCleaner.requestBody(
            transcript: "use telnex", targetBundleID: "com.openai.codex",
            vocabulary: vocabulary, model: .sonnet55
        )
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first)
        XCTAssertEqual(system["cache_control"] as? [String: String], ["type": "ephemeral"])
        let text = try XCTUnwrap(system["text"] as? String)
        XCTAssertTrue(text.hasSuffix("Telnyx (often misheard as: telnex)"))
        XCTAssertFalse(text.contains("{vocab}"))
        // The transcript must stay out of the cached prefix.
        XCTAssertFalse(text.contains("use telnex"))
        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["content"] as? String,
                       "App: com.openai.codex\n\n<transcript>\nuse telnex\n</transcript>")
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "between_tools"])
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])

        let haiku = ClaudeCleaner.requestBody(
            transcript: "x", targetBundleID: nil, vocabulary: vocabulary, model: .haiku55)
        XCTAssertEqual(haiku["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(haiku["output_config"] as? [String: String], ["effort": "medium"])
        XCTAssertEqual(ClaudeCleanupPrompt.system(vocabulary: vocabulary), text,
                       "system prompt must be byte-stable for caching")
    }

    func testParseReplyJoinsTextBlocksAndSkipsThinking() throws {
        let data = Data("""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Run the tests."},{"type":"text","text":" Then ship."}],"stop_reason":"end_turn"}
        """.utf8)
        XCTAssertEqual(try ClaudeCleaner.parseReply(data), "Run the tests. Then ship.")
    }

    func testParseReplyRejectsRefusalsAndTruncation() {
        for stop in ["refusal", "max_tokens"] {
            let data = Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"\#(stop)"}"#.utf8)
            XCTAssertThrowsError(try ClaudeCleaner.parseReply(data)) { error in
                XCTAssertEqual(error as? ClaudeCleaner.CleanupError, .stopped(stop))
            }
        }
        XCTAssertThrowsError(try ClaudeCleaner.parseReply(Data("not json".utf8)))
    }

    func testPolicySkipsShortTextAndTerminals() {
        XCTAssertFalse(ClaudeCleanupPolicy.shouldClean("Does this work?", isTerminal: false))
        XCTAssertTrue(ClaudeCleanupPolicy.shouldClean("Please run all the tests", isTerminal: false))
        XCTAssertFalse(ClaudeCleanupPolicy.shouldClean("Please run all the tests", isTerminal: true))
    }

    func testPlausibilityRejectsAnswersAndTruncations() {
        let input = "Can you look at the deploy logs and tell me why the build is failing on Railway right now"
        XCTAssertTrue(ClaudeCleanupPolicy.isPlausibleEdit(
            of: input, output: "Can you look at the deploy logs and tell me why the build is failing on Railway?"))
        XCTAssertFalse(ClaudeCleanupPolicy.isPlausibleEdit(of: input, output: "Sure."))
        XCTAssertFalse(ClaudeCleanupPolicy.isPlausibleEdit(
            of: input, output: String(repeating: "Here is a detailed explanation of the failure. ", count: 10)))
        XCTAssertFalse(ClaudeCleanupPolicy.isPlausibleEdit(of: input, output: "   "))
    }

    func testCleanSendsHeadersAndReturnsEditedText() async throws {
        let session = StubURLProtocol.session { request in
            XCTAssertEqual(request.url, ClaudeCleaner.endpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            return (200, #"{"content":[{"type":"text","text":"Run the tests on Railway, then ship."}],"stop_reason":"end_turn"}"#)
        }
        let cleaned = try await ClaudeCleaner(session: session).clean(
            "so um run the tests on railway and then ship",
            targetBundleID: nil, vocabulary: [], model: .haiku55, apiKey: "sk-test", timeout: 3)
        XCTAssertEqual(cleaned, "Run the tests on Railway, then ship.")
    }

    func testCleanThrowsOnHTTPErrorAndImplausibleReply() async {
        let failing = StubURLProtocol.session { _ in (529, #"{"type":"error"}"#) }
        do {
            _ = try await ClaudeCleaner(session: failing).clean(
                "run the tests and then ship it", targetBundleID: nil, vocabulary: [],
                model: .sonnet55, apiKey: "k", timeout: 3)
            XCTFail("expected HTTP error")
        } catch let error as ClaudeCleaner.CleanupError {
            guard case .http(529, _) = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }

        let answering = StubURLProtocol.session { _ in
            (200, #"{"content":[{"type":"text","text":"Sure."}],"stop_reason":"end_turn"}"#)
        }
        do {
            _ = try await ClaudeCleaner(session: answering).clean(
                "could you explain to me how the whole deploy pipeline works end to end",
                targetBundleID: nil, vocabulary: [], model: .sonnet55, apiKey: "k", timeout: 3)
            XCTFail("expected implausible")
        } catch {
            XCTAssertEqual(error as? ClaudeCleaner.CleanupError, .implausible)
        }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-ID": id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub-ID") ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
