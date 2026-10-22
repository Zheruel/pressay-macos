import XCTest
@testable import PressayCore

final class ASRModelTests: XCTestCase {
    func testRetiredAndAbsentValuesFallBackToTheDefault() {
        for stored in ["parakeetV3", "whisperKit", "", "nonsense"] {
            XCTAssertEqual(
                ASRModel.migrating(storedRawValue: stored), .orukeet, "stored=\(stored)")
        }
        XCTAssertEqual(ASRModel.migrating(storedRawValue: nil), .orukeet)
    }

    func testAShippingSelectionIsPreserved() {
        for model in ASRModel.allCases {
            XCTAssertEqual(ASRModel.migrating(storedRawValue: model.rawValue), model)
        }
    }

    func testEveryModelHasADistinctArtifact() {
        for model in ASRModel.allCases where model != .megaASR {
            XCTAssertNotNil(model.ggufDownload, "\(model.rawValue) has no GGUF")
        }
        // A shared filename would let the stale-artifact sweep delete a file another model needs.
        let names = ASRModel.allCases.compactMap { $0.ggufDownload?.fileName }
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testRecommendedModelsHavePinnedIntegrityCheckedArtifacts() {
        for model in ASRModel.recommended {
            XCTAssertFalse(model.workerArtifacts.isEmpty)
            for artifact in model.workerArtifacts {
                XCTAssertGreaterThan(artifact.bytes, 0)
                XCTAssertEqual(artifact.sha256.count, 64)
                XCTAssertFalse(artifact.url.path.contains("/main/"))
            }
        }
    }

    func testDefaultLanguageIsAlwaysSelectable() {
        for model in ASRModel.allCases {
            XCTAssertFalse(model.supportedLanguages.isEmpty, "\(model.rawValue)")
            XCTAssertTrue(
                model.supportedLanguages.contains(model.defaultLanguage),
                "\(model.rawValue) defaults to a language it does not offer")
        }
    }

    func testModelsWithoutAHintNeverOfferAFixedLanguage() {
        // Offering a choice would imply a hint the model rejects.
        for model in ASRModel.allCases where !model.supportsLanguageHint {
            XCTAssertEqual(model.supportedLanguages.count, 1, "\(model.rawValue)")
            XCTAssertFalse(model.offersLanguageChoice, "\(model.rawValue)")
        }
    }

    func testAssistantRefusalIsSuppressed() {
        let model = ASRModel.voxtralMini
        XCTAssertTrue(model.isTranscriptionRefusal("I'm sorry, I didn't understand."))
        XCTAssertTrue(model.isTranscriptionRefusal("Sorry, I didn't understand you."))
        XCTAssertTrue(
            model.isTranscriptionRefusal("I'm sorry, I didn't understand. Could you repeat?"))
    }

    func testWhisperNeverTreatsAnApologyAsARefusal() {
        // Whisper emits no assistant replies; filtering would drop a real dictation.
        XCTAssertFalse(
            ASRModel.whisperTurboGGML.isTranscriptionRefusal("I'm sorry, I didn't understand."))
    }

    func testRealDictationStartingWithApologyIsKept() {
        XCTAssertFalse(ASRModel.funASRMLTNano.isTranscriptionRefusal(
            "I'm sorry, I didn't understand the API design you proposed — walk me through it?"))
        XCTAssertFalse(ASRModel.funASRMLTNano.isTranscriptionRefusal("Let's ship the release today."))
    }

    func testForeignScriptOnAnEnglishOnlyModelIsSuppressed() {
        // Hallucinated on near-silent clips.
        for model in [ASRModel.funASRMLTNano, .qwen3ASR17, .qwen3ASR06] {
            XCTAssertTrue(model.isTranscriptionRefusal("아, 그거는."), "\(model.rawValue)")
            XCTAssertTrue(model.isTranscriptionRefusal("그는 그의 정체성을 가진 것이다."), "\(model.rawValue)")
        }
    }

    func testForeignScriptIsKeptWhenTheModelCanTranscribeIt() {
        XCTAssertFalse(ASRModel.whisperTurboGGML.isTranscriptionRefusal("아, 그거는."))
        XCTAssertFalse(ASRModel.whisperTurboGGML.isTranscriptionRefusal("这是一个测试。"))
        XCTAssertFalse(ASRModel.whisperTurboGGML.isTranscriptionRefusal("Это тест."))
    }

    func testEnglishWithPunctuationAndAccentsIsNotForeign() {
        XCTAssertFalse(ASRModel.isPredominantlyNonLatin("Ship it — 2 PRs, ~30% faster."))
        XCTAssertFalse(ASRModel.isPredominantlyNonLatin("naïve café résumé"))
        XCTAssertFalse(ASRModel.isPredominantlyNonLatin("..."))
        XCTAssertFalse(ASRModel.isPredominantlyNonLatin(""))
    }
}
