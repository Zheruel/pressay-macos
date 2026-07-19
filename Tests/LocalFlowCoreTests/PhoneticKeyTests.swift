import XCTest
@testable import LocalFlowCore

final class PhoneticKeyTests: XCTestCase {
    func testKeysCollapseToSameFormForKnownMishearings() {
        XCTAssertEqual(PhoneticKey.key("kimmy"), PhoneticKey.key("kimi"))
        XCTAssertEqual(PhoneticKey.key("cloud code"), PhoneticKey.key("claude code"))
        XCTAssertEqual(PhoneticKey.key("whisperflow"), PhoneticKey.key("wispr flow"))
    }

    func testNearDistancesMatchCorpusFindings() {
        XCTAssertEqual(PhoneticKey.distance(PhoneticKey.key("entropic"), PhoneticKey.key("anthropic")), 1)
        XCTAssertEqual(PhoneticKey.distance(PhoneticKey.key("rumpod"), key("runpod")), 1)
        XCTAssertEqual(PhoneticKey.distance(PhoneticKey.key("etc so"), PhoneticKey.key("codex")), 1)
        XCTAssertEqual(PhoneticKey.distance(PhoneticKey.key("chrome"), PhoneticKey.key("core ml")), 1)
    }

    func testShortCommonWordCollidesWithTechTerm() {
        // Documents why the English stop list — not the matcher — owns the
        // "makes" rejection: identical keys are expected here.
        XCTAssertEqual(PhoneticKey.key("makes"), PhoneticKey.key("macOS"))
    }

    func testDistanceBasics() {
        XCTAssertEqual(PhoneticKey.distance("", "AB"), 2)
        XCTAssertEqual(PhoneticKey.distance("ABC", "ABC"), 0)
        XCTAssertEqual(PhoneticKey.distance("ABC", "ABD"), 1)
        XCTAssertEqual(PhoneticKey.distance("ABCD", "ACD"), 1)
    }

    private func key(_ phrase: String) -> String { PhoneticKey.key(phrase) }
}
