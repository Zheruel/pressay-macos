import XCTest
@testable import PressayCore

final class ASRModelTests: XCTestCase {
    func testShippingModelSet() {
        XCTAssertEqual(
            Set(ASRModel.allCases.map(\.rawValue)),
            ["funASRMLTNano", "whisperTurboGGML", "voxtralMini"])
    }

    func testRetiredModelsAreGone() {
        for retired in ["parakeetV3", "whisperKit", "qwen3ASR17B"] {
            XCTAssertNil(ASRModel(rawValue: retired))
        }
    }

    // MARK: - Migration of persisted settings

    func testRetiredAndAbsentValuesFallBackToTheDefault() {
        for stored in ["parakeetV3", "whisperKit", "", "nonsense"] {
            XCTAssertEqual(
                ASRModel.migrating(storedRawValue: stored), .funASRMLTNano, "stored=\(stored)")
        }
        // A fresh install has nothing persisted at all.
        XCTAssertEqual(ASRModel.migrating(storedRawValue: nil), .funASRMLTNano)
    }

    func testAShippingSelectionIsPreserved() {
        for model in ASRModel.allCases {
            XCTAssertEqual(ASRModel.migrating(storedRawValue: model.rawValue), model)
        }
    }

    func testEveryModelHasADistinctArtifact() {
        for model in ASRModel.allCases {
            XCTAssertNotNil(model.ggufDownload, "\(model.rawValue) has no GGUF")
        }
        // Two entries sharing a filename would make the stale-artifact sweep
        // delete a file another model still needs.
        let names = ASRModel.allCases.compactMap { $0.ggufDownload?.fileName }
        XCTAssertEqual(Set(names).count, names.count)
    }

    // MARK: - Language coverage

    func testDefaultLanguageIsAlwaysSelectable() {
        for model in ASRModel.allCases {
            XCTAssertFalse(model.supportedLanguages.isEmpty, "\(model.rawValue)")
            XCTAssertTrue(
                model.supportedLanguages.contains(model.defaultLanguage),
                "\(model.rawValue) defaults to a language it does not offer")
        }
    }

    func testModelsWithoutAHintNeverOfferAFixedLanguage() {
        // A model that cannot take a hint can only ever run on auto-detect;
        // offering a fixed language would send it a hint it rejects.
        for model in ASRModel.allCases where !model.supportsLanguageHint {
            XCTAssertEqual(model.supportedLanguages, [.auto], "\(model.rawValue)")
        }
    }

    func testFunASRIsEnglishLockedBecauseAutoDetectHallucinates() {
        // Left on auto-detect this model invented whole sentences in Korean
        // and Spanish for near-silent clips; the English lock is the fix.
        XCTAssertEqual(ASRModel.funASRMLTNano.supportedLanguages, [.english])
        XCTAssertFalse(ASRModel.funASRMLTNano.supportedLanguages.contains(.auto))
        XCTAssertEqual(ASRModel.funASRMLTNano.defaultLanguage, .english)
        XCTAssertFalse(ASRModel.funASRMLTNano.offersLanguageChoice)
    }

    func testVoxtralOffersItsAdvertisedLanguagesAndDefaultsToAutomatic() {
        let vox = ASRModel.voxtralMini
        XCTAssertEqual(vox.defaultLanguage, .auto)
        XCTAssertTrue(vox.offersLanguageChoice)
        XCTAssertTrue(vox.supportsLanguageHint)
        // Mistral advertises exactly these eight, plus detection.
        XCTAssertEqual(Set(vox.supportedLanguages), Set<TranscriptionLanguage>(
            [.auto, .english, .french, .german, .spanish, .italian,
             .portuguese, .dutch, .hindi]))
        // Anything it cannot decode must not be offered.
        XCTAssertFalse(vox.supportedLanguages.contains(.norwegian))
        XCTAssertFalse(vox.supportedLanguages.contains(.japanese))
    }

    func testWhisperKeepsFullLanguageCoverage() {
        XCTAssertEqual(
            ASRModel.whisperTurboGGML.supportedLanguages, TranscriptionLanguage.allCases)
        XCTAssertTrue(ASRModel.whisperTurboGGML.offersLanguageChoice)
        XCTAssertTrue(ASRModel.whisperTurboGGML.supportsLanguageHint)
    }

    func testOnlyTheEngineThatNeedsItRequestsFormatting() {
        // Fun-ASR emits verbatim lowercase unless ITN is asked for. The two
        // engines calibrated in earlier releases expose no such toggle and
        // must keep the defaults those calibrations were measured against.
        XCTAssertTrue(ASRModel.funASRMLTNano.requestsExplicitFormatting)
        XCTAssertFalse(ASRModel.whisperTurboGGML.requestsExplicitFormatting)
        XCTAssertFalse(ASRModel.voxtralMini.requestsExplicitFormatting)
    }

    func testOnlyTheAutoregressiveEnginesChunkLongAudio() {
        // Whisper chunks inside the runtime, so asking Pressay to split for it
        // would add work for nothing.
        XCTAssertNil(ASRModel.whisperTurboGGML.preferredChunkSeconds)
        // The measured floor: below ~40 s the per-call overhead makes long
        // dictations slower rather than faster.
        for model in [ASRModel.funASRMLTNano, .voxtralMini] {
            let seconds = try? XCTUnwrap(model.preferredChunkSeconds)
            XCTAssertEqual(seconds, 60, "\(model.rawValue)")
        }
    }

    // MARK: - Refusal and hallucination filtering

    func testAssistantRefusalIsSuppressed() {
        let model = ASRModel.voxtralMini
        XCTAssertTrue(model.isTranscriptionRefusal("I'm sorry, I didn't understand."))
        XCTAssertTrue(model.isTranscriptionRefusal("Sorry, I didn't understand you."))
        XCTAssertTrue(
            model.isTranscriptionRefusal("I'm sorry, I didn't understand. Could you repeat?"))
    }

    func testWhisperNeverTreatsAnApologyAsARefusal() {
        // Whisper emits no assistant replies, so the filter stays off there —
        // otherwise a real dictation of this sentence would be dropped.
        XCTAssertFalse(
            ASRModel.whisperTurboGGML.isTranscriptionRefusal("I'm sorry, I didn't understand."))
    }

    func testRealDictationStartingWithApologyIsKept() {
        // Long and self-contained: a genuine dictation, not a refusal.
        XCTAssertFalse(ASRModel.funASRMLTNano.isTranscriptionRefusal(
            "I'm sorry, I didn't understand the API design you proposed — walk me through it?"))
        XCTAssertFalse(ASRModel.funASRMLTNano.isTranscriptionRefusal("Let's ship the release today."))
    }

    func testForeignScriptOnAnEnglishOnlyModelIsSuppressed() {
        // Both observed on near-silent clips during the corpus sweep.
        XCTAssertTrue(ASRModel.funASRMLTNano.isTranscriptionRefusal("아, 그거는."))
        XCTAssertTrue(ASRModel.funASRMLTNano.isTranscriptionRefusal("그는 그의 정체성을 가진 것이다."))
    }

    func testForeignScriptIsKeptWhenTheModelCanTranscribeIt() {
        // Whisper legitimately returns these scripts; dropping them would
        // silently break every non-Latin language it supports.
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

    func testLatinScriptClassification() {
        XCTAssertTrue(TranscriptionLanguage.english.usesLatinScript)
        XCTAssertTrue(TranscriptionLanguage.norwegian.usesLatinScript)
        // Automatic may return any script, so it cannot be treated as Latin.
        XCTAssertFalse(TranscriptionLanguage.auto.usesLatinScript)
        XCTAssertFalse(TranscriptionLanguage.korean.usesLatinScript)
        XCTAssertFalse(TranscriptionLanguage.russian.usesLatinScript)
    }
}
