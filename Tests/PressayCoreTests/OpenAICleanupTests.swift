import Foundation
import XCTest
@testable import PressayCore

private final class CleanupSocketStub: OpenAICleanupSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Data]
    private var sent = 0
    private var closed = 0
    private var pings = 0
    private let failure: Bool
    private let stalls: Bool
    private var firstReceiveDelay: Duration?
    private let pingDelay: Duration?
    init(_ events: [String] = [], failure: Bool = false, stalls: Bool = false, firstReceiveDelay: Duration? = nil, pingDelay: Duration? = nil) {
        self.events = events.map { Data($0.utf8) }
        self.failure = failure
        self.stalls = stalls
        self.firstReceiveDelay = firstReceiveDelay
        self.pingDelay = pingDelay
    }
    var counts: (sent: Int, closed: Int, pings: Int) { lock.withLock { (sent, closed, pings) } }
    func send(_ data: Data) async throws {
        lock.withLock { sent += 1 }
        if failure { throw URLError(.networkConnectionLost) }
    }
    func receive() async throws -> Data {
        if stalls { try await Task.sleep(for: .seconds(60)) }
        let delay = lock.withLock { let delay = firstReceiveDelay; firstReceiveDelay = nil; return delay }
        if let delay { try await Task.sleep(for: delay) }
        return try lock.withLock {
            guard !events.isEmpty else { throw URLError(.networkConnectionLost) }
            return events.removeFirst()
        }
    }
    func ping() async throws {
        lock.withLock { pings += 1 }
        if let pingDelay { try await Task.sleep(for: pingDelay) }
    }
    func close() { lock.withLock { closed += 1 } }
}

final class OpenAICleanupTests: XCTestCase, @unchecked Sendable {
    private let response = [
        #"{"type":"response.output_text.delta","delta":"Hello there."}"#,
        #"{"type":"response.completed","response":{"status":"completed","service_tier":"default"}}"#,
    ]

    func testBothTransportsUseFixedFastModel() {
        for ws in [false, true] {
            let body = OpenAICleaner.requestBody(transcript: "hello", targetBundleID: nil, vocabulary: [], webSocket: ws)
            XCTAssertEqual(body["model"] as? String, ChatGPTCleanupModel.dictationSlug)
            XCTAssertEqual(body["service_tier"] as? String, "priority")
            XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], ChatGPTCleanupModel.dictationEffort)
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(body["stream"] as? Bool, ws ? nil : true)
            XCTAssertEqual(body["type"] as? String, ws ? "response.create" : nil)
            XCTAssertNil(body["previous_response_id"])
        }
    }

    func testSuccessfulConnectionIsReusedAndDefaultReportedTierAccepted() async throws {
        let socket = CleanupSocketStub(response + response)
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("Unexpected HTTP fallback"); return ""
        })
        for _ in 0..<2 {
            let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "token", timeout: 3)
            XCTAssertEqual(result, "Hello there.")
        }
        XCTAssertEqual(socket.counts.sent, 2)
        XCTAssertEqual(socket.counts.closed, 0)
        await cleaner.invalidate()
        XCTAssertEqual(socket.counts.closed, 1)
    }

    func testTransportFailureFallsBackWithRemainingBudgetAndFastBody() async throws {
        let socket = CleanupSocketStub(failure: true)
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { data, credential, remaining in
            XCTAssertEqual(credential, "key")
            XCTAssertGreaterThan(remaining, 0)
            XCTAssertLessThanOrEqual(remaining, 3)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["service_tier"] as? String, "priority")
            XCTAssertEqual(body["stream"] as? Bool, true)
            return "Hello there."
        })
        let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 3)
        XCTAssertEqual(result, "Hello there.")
        XCTAssertGreaterThan(socket.counts.closed, 0)
    }

    func testRefusalAndInvalidEditNeverFallBack() async {
        for events in [[#"{"type":"response.refusal.delta","delta":"No"}"#], [#"{"type":"response.completed"}"#]] {
            let socket = CleanupSocketStub(events)
            let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
                XCTFail("A terminal result must not be retried"); return "Hello there."
            })
            do {
                _ = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "token", timeout: 3)
                XCTFail("Expected rejection")
            } catch { XCTAssertTrue(error is ChatGPTCleaner.CleanupError) }
        }
    }

    func testCredentialRotationClosesOldSocket() async throws {
        let first = CleanupSocketStub(response)
        let second = CleanupSocketStub(response)
        let cleaner = OpenAICleaner(makeSocket: { $0 == "first" ? first : second }, httpStream: { _, _, _ in
            XCTFail("Unexpected HTTP fallback"); return ""
        })
        _ = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "first", timeout: 3)
        _ = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "second", timeout: 3)
        XCTAssertEqual(first.counts.closed, 1)
        XCTAssertEqual(second.counts.closed, 0)
    }

    func testCancellationClosesSocketWithoutFallback() async throws {
        let socket = CleanupSocketStub(stalls: true)
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("Cancellation must not fall back"); return ""
        })
        let task = Task {
            try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 10)
        }
        while socket.counts.sent == 0 { try await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(socket.counts.closed, 0)
    }

    func testConcurrentCallUsesHTTPWithoutSharingSocketReader() async throws {
        let socket = CleanupSocketStub(stalls: true)
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in "Hello there." })
        let first = Task {
            try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 10)
        }
        while socket.counts.sent == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let second = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 3)
        XCTAssertEqual(second, "Hello there.")
        XCTAssertEqual(socket.counts.sent, 1)
        first.cancel()
        _ = try? await first.value
    }

    func testHealthyResponseCanUseMoreThanSixtyPercentOfDeadline() async throws {
        let socket = CleanupSocketStub(response, firstReceiveDelay: .milliseconds(750))
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("A healthy WebSocket response must keep its full budget"); return ""
        })
        let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 1)
        XCTAssertEqual(result, "Hello there.")
        XCTAssertEqual(socket.counts.closed, 0)
    }

    func testGlobalDeadlineClosesSocketWithoutStartingHTTP() async {
        let socket = CleanupSocketStub(stalls: true)
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("No HTTP request may start after the deadline"); return ""
        })
        let start = ContinuousClock.now
        do {
            _ = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is PressayError) }
        XCTAssertLessThan(start.duration(to: .now).seconds, 1)
        XCTAssertGreaterThan(socket.counts.closed, 0)
    }

    func testRetiredRequestCannotCloseReplacementOrFallBack() async throws {
        let firstSocket = CleanupSocketStub(stalls: true)
        let secondSocket = CleanupSocketStub(response, firstReceiveDelay: .milliseconds(150))
        let cleaner = OpenAICleaner(makeSocket: { $0 == "old" ? firstSocket : secondSocket }, httpStream: { _, _, _ in
            XCTFail("Invalidated requests must not fall back"); return ""
        })
        let first = Task {
            try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "old", timeout: 0.05)
        }
        while firstSocket.counts.sent == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "new", timeout: 1)
        XCTAssertEqual(result, "Hello there.")
        do { _ = try await first.value; XCTFail("Expected invalidation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(secondSocket.counts.closed, 0)
    }

    func testCleanupWaitsForPendingPingAndReusesSocket() async throws {
        let socket = CleanupSocketStub(response, pingDelay: .milliseconds(100))
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("Pending preparation must not force HTTP"); return ""
        })
        let warmup = Task { await cleaner.warmUp(credential: "key") }
        while socket.counts.pings == 0 { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(socket.counts.sent, 0, "Preparation must not create a model response")
        let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 1)
        await warmup.value
        XCTAssertEqual(result, "Hello there.")
        XCTAssertEqual(socket.counts.pings, 1)
        XCTAssertEqual(socket.counts.sent, 1)
        XCTAssertEqual(socket.counts.closed, 0)
    }

    func testPendingPingSharesCleanupDeadline() async throws {
        let socket = CleanupSocketStub(response, pingDelay: .seconds(2))
        let cleaner = OpenAICleaner(makeSocket: { _ in socket }, httpStream: { _, _, _ in
            XCTFail("Expired preparation must not start HTTP"); return ""
        })
        let warmup = Task { await cleaner.warmUp(credential: "key") }
        while socket.counts.pings == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let start = ContinuousClock.now
        do {
            _ = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "key", timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error is PressayError) }
        await warmup.value
        XCTAssertLessThan(start.duration(to: .now).seconds, 1)
        XCTAssertEqual(socket.counts.sent, 0)
        XCTAssertGreaterThan(socket.counts.closed, 0)
    }

    func testCredentialRotationDuringPingDoesNotCloseNewSocket() async throws {
        let oldSocket = CleanupSocketStub(pingDelay: .seconds(2))
        let newSocket = CleanupSocketStub(response)
        let cleaner = OpenAICleaner(makeSocket: { $0 == "old" ? oldSocket : newSocket }, httpStream: { _, _, _ in
            XCTFail("Credential rotation should create a fresh WebSocket"); return ""
        })
        let warmup = Task { await cleaner.warmUp(credential: "old") }
        while oldSocket.counts.pings == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let result = try await cleaner.clean("hello there", targetBundleID: nil, vocabulary: [], credential: "new", timeout: 1)
        await warmup.value
        XCTAssertEqual(result, "Hello there.")
        XCTAssertGreaterThan(oldSocket.counts.closed, 0)
        XCTAssertEqual(oldSocket.counts.sent, 0)
        XCTAssertEqual(newSocket.counts.closed, 0)
    }

    func testStreamAccumulatesAndRejectsIncomplete() throws {
        var reader = SSEReader()
        for text in ["Hello", " there."] {
            XCTAssertNil(try OpenAICleaner.handle(["type": "response.output_text.delta", "delta": text], into: &reader))
        }
        XCTAssertEqual(try OpenAICleaner.handle(["type": "response.completed"], into: &reader), "Hello there.")
        XCTAssertThrowsError(try OpenAICleaner.handle(["type": "response.incomplete"], into: &reader))
    }
}
