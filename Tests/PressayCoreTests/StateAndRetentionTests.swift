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

    func testPinnedRecordsNeverExpire() {
        let policy = RetentionPolicy(textDays: 30, audioDays: 7)
        let old = Date(timeIntervalSinceNow: -90 * 86_400)
        XCTAssertTrue(policy.shouldDeleteText(createdAt: old, isPinned: false))
        XCTAssertTrue(policy.shouldDeleteAudio(createdAt: old, isPinned: false))
        XCTAssertFalse(policy.shouldDeleteText(createdAt: old, isPinned: true))
        XCTAssertFalse(policy.shouldDeleteAudio(createdAt: old, isPinned: true))
    }
}
