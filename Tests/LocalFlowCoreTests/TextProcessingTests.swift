import XCTest
@testable import LocalFlowCore

final class TextProcessingTests: XCTestCase {
    func testCuratedVocabularyRepairsCodingAndSlackTerms() {
        let entries = VocabularyParser.parse(CuratedVocabulary.source)
        let source = "Send a slack d m with the git hub p r link. Use swift ui, swift data, core ml, and fluid audio on mac os. Update package json using camel case."

        XCTAssertEqual(
            VocabularyParser.normalize(source, entries: entries),
            "Send a Slack DM with the GitHub PR link. Use SwiftUI, SwiftData, Core ML, and FluidAudio on macOS. Update package.json using camelCase."
        )
    }

    func testCuratedVocabularyIsUniqueAndExcludesAmbiguousEnglishWords() {
        let entries = VocabularyParser.parse(CuratedVocabulary.source)
        let preferred = entries.map { $0.preferred.lowercased() }

        XCTAssertGreaterThan(entries.count, 80)
        XCTAssertEqual(Set(preferred).count, preferred.count)
        for unsafe in ["go", "react", "rest", "bun", "yarn", "linear", "terminal"] {
            XCTAssertFalse(preferred.contains(unsafe))
        }
    }

    func testAudioResamplerRejectsAboveNyquistAliasing() throws {
        let sourceRate = 48_000.0
        let source = (0..<48_000).map { index in
            Float(sin(2 * Double.pi * 18_000 * Double(index) / sourceRate))
        }

        let converted = try AudioResampler.convert(source, from: sourceRate)
        let settled = converted.dropFirst(1_024).dropLast(1_024)
        let rms = sqrt(settled.reduce(0.0) { $0 + Double($1 * $1) } / Double(settled.count))

        XCTAssertEqual(converted.count, 16_000, accuracy: 1)
        XCTAssertLessThan(rms, 0.001)
    }

    func testParsesAndAppliesVocabularyAliases() {
        let entries = VocabularyParser.parse("""
        WhisperKit <= whisper kit
        Core ML <= core ml, core em el
        """)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            VocabularyParser.normalize("use whisper kit with core ml", entries: entries),
            "use WhisperKit with Core ML"
        )
    }

    func testAppliesSpokenFormattingAndFillers() {
        let output = DeterministicPromptCleaner.clean("um implement the parser new paragraph bullet add tests")
        XCTAssertEqual(output, "Implement the parser\n\n• add tests")
    }

    func testScratchThatRemovesOnlyCurrentClause() {
        let output = DeterministicPromptCleaner.clean("Keep the API stable. use JSON scratch that use SQLite")
        XCTAssertEqual(output, "Keep the API stable. use SQLite")
    }

    func testScratchThatPreservesCoordinatedConstraint() {
        let output = DeterministicPromptCleaner.clean(
            "Do not change the API and use JSON scratch that use SQLite"
        )
        XCTAssertEqual(output, "Do not change the API and use SQLite")
    }

    func testAmbiguousScratchThatNeverDropsProtectedConstraint() {
        let source = "Do not change the API while trying JSON scratch that use SQLite"
        XCTAssertEqual(DeterministicPromptCleaner.clean(source), source)
    }

    func testPolishGateRunsOnlyForLikelyUsefulRewrites() {
        XCTAssertFalse(PromptPolishGate.shouldUseLanguageModel(
            for: "Update issue 4821 without deleting the regression tests."
        ))
        XCTAssertTrue(PromptPolishGate.shouldUseLanguageModel(
            for: "Um, can you take a look at the failing test?"
        ))
        XCTAssertTrue(PromptPolishGate.shouldUseLanguageModel(
            for: "Use JSON scratch that use SQLite."
        ))
    }

    func testValidatorPreservesCriticalTokens() {
        let validator = ProtectedTokenValidator()
        let valid = validator.validate(
            source: "Do not change parseJSON in v2.4; keep https://example.com/a.",
            candidate: "Do not modify parseJSON in v2.4. Keep https://example.com/a.",
            vocabulary: []
        )
        XCTAssertTrue(valid.isValid)

        let invalid = validator.validate(
            source: "Do not change parseJSON in v2.4.",
            candidate: "Change the parser in v3.0.",
            vocabulary: []
        )
        XCTAssertFalse(invalid.isValid)
    }

    func testValidatorRejectsInventedCriticalTokensAndLostUncertainty() {
        let validator = ProtectedTokenValidator()
        XCTAssertFalse(validator.validate(
            source: "Maybe update the parser.",
            candidate: "Update the parser in v3.0.",
            vocabulary: []
        ).isValid)
        XCTAssertFalse(validator.validate(
            source: "I think this could fix issue 42.",
            candidate: "This fixes issue 42.",
            vocabulary: []
        ).isValid)
    }

    func testConservativeTrimmerKeepsPadding() throws {
        let silence = [Float](repeating: 0, count: 8_000)
        let speech = [Float](repeating: 0.04, count: 8_000)
        let trimmed = try AudioTrimmer.trim(silence + speech + silence)
        XCTAssertGreaterThan(trimmed.count, speech.count)
        XCTAssertLessThan(trimmed.count, silence.count * 2 + speech.count)
    }

    func testShortSpeechIsPaddedForWhisper() throws {
        let silence = [Float](repeating: 0, count: 1_000)
        let speech = [Float](repeating: 0.04, count: 4_000)
        let trimmed = try AudioTrimmer.trim(silence + speech + silence)
        XCTAssertEqual(trimmed.count, 19_200)
        XCTAssertTrue(trimmed.contains(0.04))
    }

    func testProcessingPolicyKeepsNormalPathFastAndAllowsLongPrompts() {
        XCTAssertEqual(DictationProcessingPolicy.asrTimeout(duration: 10), 1.85)
        XCTAssertGreaterThan(DictationProcessingPolicy.asrTimeout(duration: 110), 10)
        XCTAssertTrue(DictationProcessingPolicy.isLongForm(duration: 110, characterCount: 100))
        XCTAssertNotNil(DictationProcessingPolicy.polishTimeout(
            duration: 110,
            characterCount: 1_500,
            elapsed: 8
        ))
        XCTAssertNil(DictationProcessingPolicy.polishTimeout(
            duration: 10,
            characterCount: 100,
            elapsed: 1.75
        ))
    }
}
