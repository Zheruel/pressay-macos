import XCTest
@testable import PressayCore

final class AudioResamplerTests: XCTestCase {
    private func sine(frequency: Double, rate: Double, duration: Double) -> [Float] {
        let count = Int(rate * duration)
        return (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    func testConvertsFortyEightKilohertzSegment() throws {
        let converted = try AudioResampler.convert(
            sine(frequency: 440, rate: 48_000, duration: 1),
            from: 48_000
        )
        XCTAssertLessThanOrEqual(abs(converted.count - 16_000), 32)
    }

    func testConvertsTwentyFourKilohertzSegment() throws {
        let converted = try AudioResampler.convert(
            sine(frequency: 440, rate: 24_000, duration: 1),
            from: 24_000
        )
        XCTAssertLessThanOrEqual(abs(converted.count - 16_000), 32)
    }

    func testMixedRateSegmentsConcatenateToExpectedLength() throws {
        let segments: [(samples: [Float], rate: Double)] = [
            (sine(frequency: 440, rate: 48_000, duration: 0.5), 48_000),
            (sine(frequency: 440, rate: 24_000, duration: 1.5), 24_000),
        ]
        let converted = try segments.flatMap {
            try AudioResampler.convert($0.samples, from: $0.rate)
        }
        XCTAssertLessThanOrEqual(abs(converted.count - 32_000), 64)
    }

    func testEmptyInputStaysEmpty() throws {
        XCTAssertTrue(try AudioResampler.convert([], from: 48_000).isEmpty)
    }

    func testMatchingRatePassesThrough() throws {
        let samples = sine(frequency: 440, rate: 16_000, duration: 0.25)
        XCTAssertEqual(try AudioResampler.convert(samples, from: 16_000), samples)
    }

    func testInvalidSourceRateThrows() {
        XCTAssertThrowsError(try AudioResampler.convert([0.1, 0.2], from: 0))
    }
}
