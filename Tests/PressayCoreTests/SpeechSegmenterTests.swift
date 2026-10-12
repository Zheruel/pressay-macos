import XCTest
@testable import PressayCore

final class SpeechSegmenterTests: XCTestCase {
    private func tone(_ seconds: Double, amplitude: Float = 0.1) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 0.06) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16_000)) }

    func testCutsAtPausesWithStartTimes() {
        var segmenter = SpeechSegmenter()
        var segments = segmenter.append(silence(1) + tone(2) + silence(1) + tone(1.5) + silence(1))
        if let last = segmenter.finish() { segments.append(last) }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.7, accuracy: 0.05, "300 ms lead-in before speech at 1 s")
        XCTAssertEqual(segments[1].start, 3.7, accuracy: 0.05)
        XCTAssertGreaterThan(segments[0].duration, 2)
        XCTAssertLessThan(segments[0].duration, 2.8)
    }

    func testLongSpeechIsSplitAtMaximumLength() {
        var segmenter = SpeechSegmenter()
        segmenter.maximumLength = 5
        var segments = segmenter.append(tone(12))
        if let last = segmenter.finish() { segments.append(last) }
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.samples.count).reduce(0, +), 12 * 16_000)
    }

    func testNoiseAndClicksAreNotSpeech() {
        var segmenter = SpeechSegmenter()
        var segments = segmenter.append(silence(3) + tone(0.1) + silence(2))
        if let last = segmenter.finish() { segments.append(last) }
        XCTAssertTrue(segments.isEmpty)
    }
}
