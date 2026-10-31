import Foundation
import Darwin
import XCTest
@testable import PressayCore

final class ClaudeCodeCleanupTests: XCTestCase {
    func testSubscriptionStatusDoesNotMistakeAPIAuthenticationForPlanUsage() throws {
        let subscription = try ClaudeCodeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#.utf8))
        XCTAssertTrue(subscription.usesSubscription)
        let api = try ClaudeCodeAuthStatus.parse(Data(#"{"loggedIn":true,"authMethod":"api_key"}"#.utf8))
        XCTAssertFalse(api.usesSubscription)
        let signedOut = try ClaudeCodeAuthStatus.parse(Data(#"{"loggedIn":false,"authMethod":"none"}"#.utf8))
        XCTAssertFalse(signedOut.usesSubscription)
    }

    func testCleanupRejectsProviderErrorsAndPartialResults() throws {
        let good = Data(#"{"type":"result","subtype":"success","is_error":false,"result":"Clean text."}"#.utf8)
        XCTAssertEqual(try ClaudeCodeCleaner.parseReply(good, exitCode: 0), "Clean text.")
        XCTAssertThrowsError(try ClaudeCodeCleaner.parseReply(good, exitCode: 1))
        for json in [
            #"{"type":"result","subtype":"error_max_turns","is_error":true,"result":"partial"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":" "}"#,
            #"{"type":"assistant","result":"wrong envelope"}"#,
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"max_tokens","result":"partial"}"#,
        ] {
            XCTAssertThrowsError(try ClaudeCodeCleaner.parseReply(Data(json.utf8), exitCode: 0))
        }
    }

    func testProcessHandlesOutputLargerThanPipeCapacity() async throws {
        let text = String(repeating: "Dictation input.\n", count: 40_000)
        let process = ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: text, timeout: 3)
        let result = try await process.run()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), text)
    }

    func testTimeoutKillsNonresponsiveProcessWithoutWaitingForExit() async {
        let process = ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], input: "", timeout: 0.06)
        let start = ContinuousClock.now
        do {
            _ = try await process.run()
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeError, .timedOut)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testCancellationReturnsPromptly() async throws {
        let task = Task {
            try await ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], input: "", timeout: 60).run()
        }
        try await Task.sleep(for: .milliseconds(60))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        }
    }

    func testAlreadyCancelledTaskDoesNotRunProcess() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ClaudeCodeProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], input: "", timeout: 60).run()
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCapabilityDetectionRejectsOlderCLI() {
        XCTAssertFalse(ClaudeCodeClient.supportsCleanup("--tools --output-format --model"))
        XCTAssertTrue(ClaudeCodeClient.supportsCleanup("--safe-mode --tools --disallowedTools --no-session-persistence --output-format --system-prompt --effort --model"))
    }
    func testPreparationReusesHelpOnceButChecksCurrentBillingBeforeCleanup() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        XCTAssertTrue(try fixture.receivedInput().allSatisfy { $0 == 10 })
        try fixture.setAuth(method: "api_key")
        do {
            _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
                targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
            XCTFail("An API-billed account must not reuse the earlier preparation as subscription auth")
        } catch { XCTAssertEqual(error as? ClaudeCodeError, .notSignedIn) }
        XCTAssertEqual(try fixture.calls().filter { $0 == "help" }.count, 1)
        XCTAssertEqual(try fixture.calls().filter { $0 == "auth" }.count, 2)
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        try fixture.setAuth(method: "claude.ai")
        _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertEqual(try fixture.calls().filter { $0 == "help" }.count, 2)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
    }

    func testCancelledPreparationDoesNotStartAuthenticationOrCleanup() async throws {
        for completeBeforeCancellation in [false, true] {
            let fixture = try CLIStub()
            defer { fixture.remove() }
            let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
            let preparation = cleaner.prepare(effort: "medium")
            if completeBeforeCancellation { try await fixture.waitForWorker() }
            preparation.cancel()
            do {
                _ = try await cleaner.clean("Check the deployment logs before fixing the failing test.",
                    targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(try fixture.calls().contains("cleanup"))
            XCTAssertTrue(try fixture.receivedInput().allSatisfy { $0 == 10 })
        }
    }

    func testPreparedWorkerWaitsForRealInputAndIsReused() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        XCTAssertTrue(try fixture.receivedInput().allSatisfy { $0 == 10 })
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        let text = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 1)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
        XCTAssertFalse(try fixture.receivedInput().allSatisfy { $0 == 10 })
    }

    func testChangedAccountOrEffortDiscardsPreparedWorker() async throws {
        for changeAccount in [true, false] {
            let fixture = try CLIStub()
            defer { fixture.remove() }
            let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
            let preparation = cleaner.prepare(effort: "medium")
            defer { preparation.cancel() }
            try await fixture.waitForWorker()
            if changeAccount { try fixture.setAuth(method: "claude.ai", identity: "account-two") }
            _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
                targetBundleID: nil, vocabulary: [], effort: changeAccount ? "medium" : "low",
                timeout: 2, preparation: preparation)
            XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 2)
            XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
        }
    }

    func testDroppingUnusedPreparationDoesNotSendInput() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        var preparation: ClaudeCodePreparation? = cleaner.prepare(effort: "medium")
        weak let reference = preparation
        try await fixture.waitForWorker()
        preparation = nil
        XCTAssertNil(reference)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        XCTAssertTrue(try fixture.receivedInput().allSatisfy { $0 == 10 })
    }

    func testPreparedResponseTimeoutDoesNotWaitForStalledChild() async throws {
        let fixture = try CLIStub(stallAfterInput: true)
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        let start = ContinuousClock.now
        do {
            _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
                targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 0.15, preparation: preparation)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? ClaudeCodeError, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testExpiredWorkerFallsBackToFreshCleanup() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let client = ClaudeCodeClient(executable: fixture.executable)
        let preparation = ClaudeCodePreparation(client: client, system: ClaudeCleanupPrompt.system(vocabulary: []),
            effort: "medium", validFor: .milliseconds(10), idleTimeout: 0.05)
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        _ = try await ClaudeCodeCleaner(client: client).clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 2)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
    }

    func testUpdatedExecutableDiscardsPreparedWorker() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        let handle = try FileHandle(forWritingTo: fixture.executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n# Updated CLI version\n".utf8))
        try handle.close()
        _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 2)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
    }

    func testPreparedLargeInputIsWrittenWithoutBlocking() async throws {
        let fixture = try CLIStub()
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        let transcript = String(repeating: "Check deployment logs and preserve API response format. ", count: 20_000)
        do {
            _ = try await cleaner.clean(transcript, targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 3, preparation: preparation)
            XCTFail("The fixture returns a short reply, which should fail plausibility")
        } catch { XCTAssertEqual(error as? ClaudeCleaner.CleanupError, .implausible) }
        XCTAssertEqual(try fixture.receivedInput(), Data(("\n" + ClaudeCleanupPrompt.user(transcript: transcript, targetBundleID: nil)).utf8))
    }

    func testBlockedAndClosedInputCannotBlockTimeoutOrRaiseSIGPIPE() async throws {
        for mode in ["blocked", "closed"] {
            let fixture = try CLIStub(inputMode: mode)
            defer { fixture.remove() }
            let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
            let preparation = cleaner.prepare(effort: "medium")
            defer { preparation.cancel() }
            try await fixture.waitForWorker()
            let pid = Int32(try String(contentsOf: fixture.directory.appendingPathComponent("worker-pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
            let started = ContinuousClock.now
            do {
                _ = try await cleaner.clean(String(repeating: "Dictated text. ", count: 100_000),
                    targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 0.15, preparation: preparation)
                XCTFail("Expected a blocked or closed pipe error")
            } catch {
                if mode == "blocked" { XCTAssertEqual(error as? ClaudeCodeError, .timedOut) }
                else { XCTAssertEqual((error as? POSIXError)?.code, .EPIPE) }
            }
            XCTAssertLessThan(started.duration(to: .now), .seconds(1))
            let exitDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while kill(pid, 0) == 0 && ContinuousClock.now < exitDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let status = kill(pid, 0)
            let error = errno
            XCTAssertEqual(status, -1, "A child ignoring SIGTERM must still be killed")
            XCTAssertEqual(error, ESRCH)
        }
    }

    func testWorkerThatExitsBeforeReceivingInputRestartsWithoutLosingDictation() async throws {
        let fixture = try CLIStub(inputMode: "exit-once")
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        let result = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 2)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
    }

    func testNewlineKeepsWorkerReadyPastItsFirstByteDeadlineWithoutSendingTranscript() async throws {
        let fixture = try CLIStub(inputMode: "first-byte-required")
        defer { fixture.remove() }
        let cleaner = ClaudeCodeCleaner(client: ClaudeCodeClient(executable: fixture.executable))
        let preparation = cleaner.prepare(effort: "medium")
        defer { preparation.cancel() }
        try await fixture.waitForWorker()
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("first-byte-received").path))
        XCTAssertEqual(try fixture.receivedInput(), Data("\n".utf8))
        XCTAssertFalse(try fixture.calls().contains("cleanup"))
        _ = try await cleaner.clean("Please check these deployment logs and fix the failing test today.",
            targetBundleID: nil, vocabulary: [], effort: "medium", timeout: 2, preparation: preparation)
        XCTAssertEqual(try fixture.calls().filter { $0 == "worker" }.count, 1)
        XCTAssertEqual(try fixture.calls().filter { $0 == "cleanup" }.count, 1)
    }

}

private struct CLIStub {
    let directory: URL
    var executable: URL { directory.appendingPathComponent("claude") }
    init(stallAfterInput: Bool = false, inputMode: String = "normal") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = """
        #!/bin/sh
        base="$(dirname "$0")"
        case "$1" in
          --help)
            echo help >> "$base/calls"
            /bin/sleep 0.15
            echo '--safe-mode --tools --disallowedTools --no-session-persistence --output-format --system-prompt --effort --model'
            ;;
          auth)
            echo auth >> "$base/calls"
            cat "$base/auth"
            ;;
          -p)
            echo worker >> "$base/calls"
            if [ "\(inputMode)" = "exit-once" ] && [ ! -f "$base/exited-once" ]; then
              touch "$base/exited-once"
              echo $$ > "$base/worker-pid"
              touch "$base/worker-ready"
              /bin/sleep 0.05
              exit 1
            fi
            echo $$ > "$base/worker-pid"
            touch "$base/worker-ready"
            \(inputMode == "closed" ? "exec 0<&-; trap '' TERM; exec /bin/sleep 30" : inputMode == "blocked" ? "trap '' TERM; exec /bin/sleep 30" : ":")
            if [ "\(inputMode)" = "first-byte-required" ]; then
              IFS= read -r -t 1 first || exit 1
              printf '%s\\n' "$first" > "$base/received"
              touch "$base/first-byte-received"
              cat >> "$base/received"
            else
              cat > "$base/received"
            fi
            [ -s "$base/received" ] || exit 0
            \(stallAfterInput ? "exec /bin/sleep 30" : ":")
            echo cleanup >> "$base/calls"
            echo '{"type":"result","subtype":"success","is_error":false,"result":"Please check these deployment logs and fix the failing test today."}'
            ;;
        esac
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try setAuth(method: "claude.ai")
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func setAuth(method: String, identity: String = "account-one") throws {
        let data = try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": method, "orgId": identity])
        try data.write(to: directory.appendingPathComponent("auth"))
    }
    func calls() throws -> [String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("calls")) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
    func receivedInput() throws -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent("received"))) ?? Data()
    }
    func waitForWorker() async throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("worker-ready").path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ClaudeCodeError.timedOut
    }
}
