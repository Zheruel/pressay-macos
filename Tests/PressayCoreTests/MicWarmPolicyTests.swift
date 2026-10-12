import XCTest
@testable import PressayCore

final class MicWarmPolicyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func conditions(
        enabled: Bool = true,
        isBluetooth: Bool = false,
        outputDeviceInUse: Bool = false,
        endedSecondsAgo: TimeInterval? = 1
    ) -> MicWarmPolicy.Conditions {
        MicWarmPolicy.Conditions(
            enabled: enabled,
            isBluetooth: isBluetooth,
            outputDeviceInUse: outputDeviceInUse,
            lastDictationEnded: endedSecondsAgo.map { epoch.addingTimeInterval(-$0) }
        )
    }

    private let window = DictationProcessingPolicy.micWarmWindow

    func testStaysWarmInsideTheWindow() {
        XCTAssertTrue(MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: 5), now: epoch))
        XCTAssertTrue(
            MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: window - 1), now: epoch)
        )
    }

    func testCoolsDownOnceTheWindowLapses() {
        XCTAssertFalse(MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: window), now: epoch))
        XCTAssertFalse(
            MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: window * 4), now: epoch)
        )
    }

    /// 35 s is the observed median gap between back-to-back dictations.
    func testWindowClearsTheObservedMedianGap() {
        XCTAssertGreaterThan(window, 35)
    }

    /// Opening the mic unprompted would light the recording indicator.
    func testNeverWarmsBeforeTheFirstDictation() {
        XCTAssertFalse(MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: nil), now: epoch))
    }

    func testDisabledSettingWins() {
        XCTAssertFalse(
            MicWarmPolicy.shouldStayWarm(conditions(enabled: false, endedSecondsAgo: 1), now: epoch)
        )
    }

    /// Holding a headset in its call profile degrades playback.
    func testBluetoothYieldsToPlayback() {
        XCTAssertFalse(
            MicWarmPolicy.shouldStayWarm(
                conditions(isBluetooth: true, outputDeviceInUse: true), now: epoch
            )
        )
        XCTAssertTrue(
            MicWarmPolicy.shouldStayWarm(
                conditions(isBluetooth: true, outputDeviceInUse: false), now: epoch
            )
        )
    }

    func testWiredInputIgnoresPlayback() {
        XCTAssertTrue(
            MicWarmPolicy.shouldStayWarm(
                conditions(isBluetooth: false, outputDeviceInUse: true), now: epoch
            )
        )
    }

    func testExpiryIsTheEndOfTheWindow() {
        let expiry = MicWarmPolicy.expiry(conditions(endedSecondsAgo: 10), now: epoch)
        XCTAssertEqual(expiry, epoch.addingTimeInterval(-10 + window))
        XCTAssertNil(MicWarmPolicy.expiry(conditions(endedSecondsAgo: window * 2), now: epoch))
    }

    /// A backwards clock jump must not slam the mic shut mid-burst.
    func testFutureTimestampStaysWarm() {
        XCTAssertTrue(MicWarmPolicy.shouldStayWarm(conditions(endedSecondsAgo: -5), now: epoch))
    }
}
