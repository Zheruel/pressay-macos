import Foundation
import XCTest
@testable import PressayCore

final class StateAndRetentionTests: XCTestCase {
    func testStateMachineRejectsOverlappingDictations() {
        var state = DictationStateMachine()
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.stop())
        state.succeed()
        XCTAssertEqual(state.phase, .succeeded)
        state.reset()
        XCTAssertEqual(state.phase, .idle)
    }

    func testArmingLeadsIntoRecording() {
        var state = DictationStateMachine()
        XCTAssertTrue(state.arm())
        XCTAssertEqual(state.phase, .arming)
        XCTAssertFalse(state.arm())
        XCTAssertTrue(state.begin())
        XCTAssertEqual(state.phase, .recording)
    }

    /// A quick tap can release the key before a cold mic ever reports audio;
    /// that must still hand off to processing instead of stranding the session.
    func testReleaseWhileArmingStillStops() {
        var state = DictationStateMachine()
        XCTAssertTrue(state.arm())
        XCTAssertTrue(state.stop())
        XCTAssertEqual(state.phase, .processing)
    }

    func testCancelWhileArmingReturnsToIdle() {
        var state = DictationStateMachine()
        XCTAssertTrue(state.arm())
        state.cancel()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.arm())
    }

    func testArmingIsRejectedWhileProcessing() {
        var state = DictationStateMachine()
        XCTAssertTrue(state.arm())
        XCTAssertTrue(state.stop())
        XCTAssertFalse(state.arm())
    }

    func testPinnedRecordsNeverExpire() {
        let policy = RetentionPolicy(textDays: 30, audioDays: 7)
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        XCTAssertTrue(policy.shouldDeleteText(createdAt: old, isPinned: false))
        XCTAssertTrue(policy.shouldDeleteAudio(createdAt: old, isPinned: false))
        XCTAssertFalse(policy.shouldDeleteText(createdAt: old, isPinned: true))
        XCTAssertFalse(policy.shouldDeleteAudio(createdAt: old, isPinned: true))
    }
}
