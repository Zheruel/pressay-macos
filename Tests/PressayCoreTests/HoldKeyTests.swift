import XCTest
@testable import PressayCore

final class HoldKeyTests: XCTestCase {
    // MARK: - Bindability

    func testEscapeAndCapsLockCanNeverBeBound() {
        XCTAssertFalse(HoldKey.isBindable(keyCode: HoldKey.escapeKeyCode))
        XCTAssertFalse(HoldKey.isBindable(keyCode: HoldKey.capsLockKeyCode))
        XCTAssertNotNil(HoldKey.rejectionReason(keyCode: HoldKey.escapeKeyCode))
        XCTAssertNotNil(HoldKey.rejectionReason(keyCode: HoldKey.capsLockKeyCode))
    }

    func testEveryOtherKeyBindsWithoutARejectionReason() {
        for code in [Int64(0), 49, 61, 63, 96, 123] {
            XCTAssertTrue(HoldKey.isBindable(keyCode: code))
            XCTAssertNil(HoldKey.rejectionReason(keyCode: code))
        }
    }

    // MARK: - Binding cost

    func testModifiersCostNothing() {
        for key in [HoldKey.rightOption, .leftOption, .rightCommand, HoldKey(keyCode: 63)] {
            XCTAssertEqual(key.bindingCost, .passesThrough, key.displayName)
            XCTAssertNil(key.cautionMessage, key.displayName)
        }
    }

    func testTypingKeysWarnThatTheyStopWorkingElsewhere() {
        // Letters, digits, punctuation, and the text-editing keys all reach an
        // app as characters, so swallowing one is felt while typing.
        for key in [HoldKey(keyCode: 1), HoldKey(keyCode: 18), HoldKey(keyCode: 49),
                    HoldKey(keyCode: 36), HoldKey(keyCode: 48), HoldKey(keyCode: 51),
                    HoldKey(keyCode: 44)] {
            XCTAssertEqual(key.bindingCost, .blocksTyping, key.displayName)
            guard let caution = key.cautionMessage else {
                XCTFail("\(key.displayName) should warn about being swallowed")
                continue
            }
            XCTAssertTrue(caution.contains(key.displayName), caution)
        }
    }

    func testFunctionAndNavigationKeysWarnMoreQuietly() {
        for key in [HoldKey(keyCode: 96), HoldKey(keyCode: 122), HoldKey(keyCode: 90),
                    HoldKey(keyCode: 123), HoldKey(keyCode: 116), HoldKey(keyCode: 117)] {
            XCTAssertEqual(key.bindingCost, .interceptsKey, key.displayName)
            XCTAssertNotNil(key.cautionMessage, key.displayName)
        }
    }

    func testUnknownKeysAreTreatedAsTypingKeys() {
        // Anything absent from the name table gets the stronger warning rather
        // than the quieter one.
        XCTAssertEqual(HoldKey(keyCode: 110).bindingCost, .blocksTyping)
    }

    func testTheKeypadIsNamedRatherThanNumbered() {
        // "Key 87" on a keycap reads as a broken picker, and the caution
        // repeats whatever this returns.
        XCTAssertEqual(HoldKey(keyCode: 87).displayName, "Keypad 5")
        XCTAssertEqual(HoldKey(keyCode: 65).displayName, "Keypad .")
        XCTAssertEqual(HoldKey(keyCode: 92).displayName, "Keypad 9")
        XCTAssertEqual(HoldKey(keyCode: 87).bindingCost, .blocksTyping)
        let keypad: [Int64] = [65, 67, 69, 71, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for code in keypad {
            XCTAssertFalse(
                HoldKey(keyCode: code).displayName.hasPrefix("Key "),
                "keypad code \(code) is unnamed"
            )
        }
    }

    // MARK: - Presentation

    func testModifiersRenderTheirEngravedGlyph() {
        XCTAssertEqual(HoldKey.rightOption.capGlyph, "⌥")
        XCTAssertEqual(HoldKey.rightCommand.capGlyph, "⌘")
        XCTAssertEqual(HoldKey(keyCode: 60).capGlyph, "⇧")
        XCTAssertEqual(HoldKey(keyCode: 59).capGlyph, "⌃")
        XCTAssertEqual(HoldKey(keyCode: 49).capGlyph, "␣")
        XCTAssertEqual(HoldKey(keyCode: 126).capGlyph, "↑")
    }

    func testKeysThatNeedNoGlyphFallBackToTheirName() {
        // The view drops the trailing name when it matches the cap, so a
        // letter or F-key must read identically both ways.
        for key in [HoldKey(keyCode: 0), HoldKey(keyCode: 29), HoldKey(keyCode: 96)] {
            XCTAssertEqual(key.capGlyph, key.displayName)
        }
    }

    func testDefaultIsRightOption() {
        XCTAssertEqual(HoldKey.default, .rightOption)
        XCTAssertNil(HoldKey.default.cautionMessage)
        XCTAssertTrue(HoldKey.default.isModifier)
    }

    // MARK: - Persistence

    func testLegacyStringValuesStillResolve() {
        XCTAssertEqual(HoldKey(legacyRawValue: "Right Option"), .rightOption)
        XCTAssertEqual(HoldKey(legacyRawValue: "Left Option"), .leftOption)
        XCTAssertNil(HoldKey(legacyRawValue: "Right Command"))
        XCTAssertNil(HoldKey(legacyRawValue: ""))
    }

    // MARK: - Modifier press detection

    private static let optionFamily: UInt64 = 0x80000
    private static let leftOptionDevice: UInt64 = 0x20
    private static let rightOptionDevice: UInt64 = 0x40

    func testDeviceBitsTellPairedModifiersApart() {
        let flags = Self.optionFamily | Self.rightOptionDevice
        XCTAssertTrue(HoldKey.rightOption.isDownAsModifier(inFlags: flags))
        XCTAssertFalse(HoldKey.leftOption.isDownAsModifier(inFlags: flags))
    }

    func testSyntheticFlagsWithoutDeviceBitsFallBackToTheFamily() {
        // Synthetic events carry the family mask alone; refusing to match it
        // would make the key look permanently up.
        XCTAssertTrue(HoldKey.rightOption.isDownAsModifier(inFlags: Self.optionFamily))
        XCTAssertTrue(HoldKey.leftOption.isDownAsModifier(inFlags: Self.optionFamily))
    }

    func testAnEmptyFlagsWordIsNeverDown() {
        XCTAssertFalse(HoldKey.rightOption.isDownAsModifier(inFlags: 0))
        XCTAssertFalse(HoldKey.rightOption.isDownAsModifier(inFlags: Self.leftOptionDevice))
    }

    func testNonModifiersAreNeverDownAsModifiers() {
        XCTAssertFalse(HoldKey(keyCode: 0).isDownAsModifier(inFlags: ~0))
    }
}
