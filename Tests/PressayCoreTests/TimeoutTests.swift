import Foundation
import XCTest
@testable import PressayCore

final class TimeoutTests: XCTestCase {
    func testTimeoutDoesNotWaitForCancellationUnawareOperation() async {
        let started = ContinuousClock.now
        do {
            _ = try await Timeout.run(for: .milliseconds(20)) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            XCTFail("Expected timeout")
        } catch PressayError.timedOut {
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .milliseconds(200))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
