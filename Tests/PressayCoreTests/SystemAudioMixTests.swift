import XCTest
@testable import PressayCore

final class SystemAudioMixTests: XCTestCase {
    func testAveragesInterleavedStereo() {
        let mixed = [Float(1), 0, 0.5, 0.5, -1, 1].withUnsafeBufferPointer { SystemAudioMix.mono($0, channels: 2) }
        XCTAssertEqual(mixed, [0.5, 0.5, 0])
    }

    func testPassesMonoThrough() {
        let mixed = [Float(0.25), -0.25].withUnsafeBufferPointer { SystemAudioMix.mono($0, channels: 1) }
        XCTAssertEqual(mixed, [0.25, -0.25])
    }
}
