import XCTest
@testable import PressayCore

final class ASRModelTests: XCTestCase {
    func testVoxtralRefusalIsSuppressed() {
        let vox = ASRModel.voxtralMini
        XCTAssertTrue(vox.isTranscriptionRefusal("I'm sorry, I didn't understand."))
        XCTAssertTrue(vox.isTranscriptionRefusal("I'm sorry, I didn't understand. Could you please repeat that?"))
        XCTAssertTrue(vox.isTranscriptionRefusal("Sorry, I didn't understand you."))
    }

    func testRealDictationStartingWithApologyIsKept() {
        let vox = ASRModel.voxtralMini
        // A genuine dictation that merely starts with an apology is long and
        // self-contained — it must not be dropped.
        XCTAssertFalse(vox.isTranscriptionRefusal(
            "I'm sorry, I didn't understand the API design you proposed — can you walk me through it again?"))
        XCTAssertFalse(vox.isTranscriptionRefusal("Let's ship the release today."))
    }

    func testWhisperNeverTreatsTextAsRefusal() {
        // Only the engine that emits the artifact is filtered.
        XCTAssertFalse(ASRModel.whisperTurboGGML.isTranscriptionRefusal("I'm sorry, I didn't understand."))
    }

    func testLanguageHintSupport() {
        XCTAssertTrue(ASRModel.whisperTurboGGML.supportsLanguageHint)
        XCTAssertTrue(ASRModel.voxtralMini.supportsLanguageHint)
    }

    func testParakeetIsRemoved() {
        XCTAssertNil(ASRModel(rawValue: "parakeetV3"))
        XCTAssertEqual(Set(ASRModel.allCases.map(\.rawValue)), ["whisperTurboGGML", "voxtralMini"])
    }
}
