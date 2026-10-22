import Foundation
import XCTest
import PressayCore
@testable import PressayTranscription

final class ASRWorkerHostTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "Pressay-worker-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func host(_ script: String, timeout: TimeInterval = 5) throws -> ASRWorkerHost {
        let worker = directory.appending(path: "worker")
        try ("#!/bin/sh\n" + script).write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        return ASRWorkerHost(executable: worker, runtime: directory, timeout: timeout)
    }

    func testReusesOneWorkerUntilModelChangesAndPreservesText() async throws {
        let trace = directory.appending(path: "loads")
        let host = try host("""
        echo "$1" >> '\(trace.path)'
        printf '{"ready":true}\\n'
        while IFS= read -r line; do
          printf '{"text":"Could or should we do that? Do that.","truncated":false}\\n'
        done
        """)
        _ = try await host.request(model: .orukeet, directory: directory, audio: nil)
        let first = try await host.request(model: .orukeet, directory: directory, audio: [0.1, -0.2])
        XCTAssertEqual(first.text, "Could or should we do that? Do that.")
        XCTAssertFalse(first.truncated)
        _ = try await host.request(model: .moss, directory: directory, audio: [0.2])
        _ = try await host.request(model: .moss, directory: directory, audio: [0.3])
        await host.release()
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8), "orukeet\nmoss\n")
    }

    func testWorkerErrorIsReportedAndNextRequestRestarts() async throws {
        let host = try host("""
        printf '{"ready":true}\\n'
        while IFS= read -r line; do printf '{"error":"Decoder failed"}\\n'; done
        """)
        for _ in 0..<2 {
            do {
                _ = try await host.request(model: .orukeet, directory: directory, audio: [0.1])
                XCTFail("Expected worker error")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Decoder failed")) }
        }
        await host.release()
    }

    func testWorkerExitCannotTerminateTheAppWithABrokenPipe() async throws {
        let host = try host("printf '{\"ready\":true}\\n'; exit 0")
        for _ in 0..<3 {
            do {
                _ = try await host.request(model: .moss, directory: directory, audio: [0.1])
                XCTFail("Expected the worker exit to be reported")
            } catch { XCTAssertFalse(error is CancellationError) }
        }
        await host.release()
    }

    func testPartialOutputRemainsMarkedTruncated() async throws {
        let host = try host("""
        printf '{"ready":true}\\n'
        while IFS= read -r line; do printf '{"text":"partial","truncated":true}\\n'; done
        """)
        let reply = try await host.request(model: .moss, directory: directory, audio: [0.1])
        XCTAssertTrue(reply.truncated, "The caller must retry rather than insert partial output as complete")
        await host.release()
    }

    func testCancellationUnblocksAHungWorker() async throws {
        let host = try host("""
        printf '{"ready":true}\\n'
        IFS= read -r line
        exec /usr/bin/tail -f /dev/null
        """)
        _ = try await host.request(model: .moss, directory: directory, audio: nil)
        let task = Task { try await host.request(model: .moss, directory: directory, audio: [0.1]) }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await host.release()
    }

    func testTimeoutUnblocksAHungWorker() async throws {
        let host = try host("exec /usr/bin/tail -f /dev/null", timeout: 0.1)
        do {
            _ = try await host.request(model: .orukeet, directory: directory, audio: nil)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        await host.release()
    }
}
