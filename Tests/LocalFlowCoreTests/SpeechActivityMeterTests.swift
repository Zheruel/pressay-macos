import XCTest
@testable import LocalFlowCore

final class SpeechActivityMeterTests: XCTestCase {
    func testSilenceAndAmbientNoiseDoNotAnimate() {
        var meter = SpeechActivityMeter()

        for _ in 0..<30 {
            let sample = meter.process(rms: 0.004, frameDuration: 1.0 / 30.0)
            XCTAssertFalse(sample.isSpeech)
            XCTAssertEqual(sample.level, 0)
        }
    }

    func testSpeechNeedsAShortAttackAndSettlesAfterPause() {
        var meter = SpeechActivityMeter()

        let isolatedPeak = meter.process(rms: 0.06, frameDuration: 1.0 / 30.0)
        XCTAssertFalse(isolatedPeak.isSpeech)

        var spoken = SpeechActivitySample(level: 0, isSpeech: false)
        for _ in 0..<3 {
            spoken = meter.process(rms: 0.06, frameDuration: 1.0 / 30.0)
        }
        XCTAssertTrue(spoken.isSpeech)
        XCTAssertGreaterThan(spoken.level, 0.2)

        for _ in 0..<4 {
            spoken = meter.process(rms: 0.002, frameDuration: 1.0 / 30.0)
        }
        XCTAssertTrue(spoken.isSpeech, "A natural word gap should not make the indicator flicker off")

        for _ in 0..<4 {
            spoken = meter.process(rms: 0.002, frameDuration: 1.0 / 30.0)
        }
        XCTAssertFalse(spoken.isSpeech)
        XCTAssertEqual(spoken.level, 0)
    }
}
