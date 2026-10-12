import XCTest
@testable import PressayCore

final class AudioChunkingTests: XCTestCase {
    private let sampleRate = 16_000

    private func clipWithGap(
        totalSeconds: Double, gapCentre: Double, gapSeconds: Double
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(totalSeconds * Double(sampleRate)))
        let gapStart = Int((gapCentre - gapSeconds / 2) * Double(sampleRate))
        let gapEnd = Int((gapCentre + gapSeconds / 2) * Double(sampleRate))
        for index in samples.indices where index < gapStart || index >= gapEnd {
            samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5
        }
        return samples
    }

    func testSplitLandsInTheSilentGap() throws {
        let samples = clipWithGap(totalSeconds: 20, gapCentre: 10, gapSeconds: 1.0)
        let point = AudioChunking.quietestSplitPoint(
            samples: samples, sampleRate: sampleRate, near: samples.count / 2)
        let seconds = Double(try XCTUnwrap(point)) / Double(sampleRate)
        XCTAssertEqual(seconds, 10, accuracy: 0.6, "split should fall inside the pause")
    }

    func testSplitFindsAnOffCentreGapWithinTheSearchWindow() throws {
        // Midpoint is 10 s; the search window is ±3 s.
        let samples = clipWithGap(totalSeconds: 20, gapCentre: 8, gapSeconds: 0.8)
        let point = AudioChunking.quietestSplitPoint(
            samples: samples, sampleRate: sampleRate, near: samples.count / 2)
        let seconds = Double(try XCTUnwrap(point)) / Double(sampleRate)
        XCTAssertEqual(seconds, 8, accuracy: 0.6)
    }

    func testUniformSpeechHasNoPauseToSplitOn() {
        let samples = clipWithGap(totalSeconds: 20, gapCentre: 10, gapSeconds: 0)
        XCTAssertNil(AudioChunking.quietestSplitPoint(
            samples: samples, sampleRate: sampleRate, near: samples.count / 2))
    }

    func testSplitPointFallsBackToTheMidpoint() {
        let samples = clipWithGap(totalSeconds: 20, gapCentre: 10, gapSeconds: 0)
        XCTAssertEqual(
            AudioChunking.splitPoint(samples: samples, sampleRate: sampleRate),
            samples.count / 2)
    }

    func testSplitPointAlwaysDividesTheBuffer() {
        for seconds in [4.0, 20.0, 103.6] {
            let samples = clipWithGap(totalSeconds: seconds, gapCentre: seconds / 2, gapSeconds: 0.5)
            let cut = AudioChunking.splitPoint(samples: samples, sampleRate: sampleRate)
            XCTAssertGreaterThan(cut, 0, "\(seconds)s produced an empty first half")
            XCTAssertLessThan(cut, samples.count, "\(seconds)s produced an empty second half")
        }
    }

    func testDegenerateInputsAreRejectedRatherThanCrashing() {
        XCTAssertNil(AudioChunking.quietestSplitPoint(
            samples: [], sampleRate: sampleRate, near: 0))
        XCTAssertNil(AudioChunking.quietestSplitPoint(
            samples: [0.1, 0.2], sampleRate: 0, near: 1))
        XCTAssertNil(AudioChunking.quietestSplitPoint(
            samples: [Float](repeating: 0, count: sampleRate), sampleRate: sampleRate,
            near: sampleRate / 2))
    }

    // MARK: - Joining

    func testJoinInsertsExactlyOneSpace() {
        XCTAssertEqual(AudioChunking.join(["First half.", "Second half."]),
                       "First half. Second half.")
        XCTAssertEqual(AudioChunking.join(["First half. ", "  Second half."]),
                       "First half. Second half.")
    }

    func testJoinDropsEmptyChunks() {
        XCTAssertEqual(AudioChunking.join(["Real speech.", "", "More speech."]),
                       "Real speech. More speech.")
        XCTAssertEqual(AudioChunking.join(["", "Only this."]), "Only this.")
        XCTAssertEqual(AudioChunking.join(["", "   ", ""]), "")
        XCTAssertEqual(AudioChunking.join([]), "")
    }
}
