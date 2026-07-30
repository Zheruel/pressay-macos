import XCTest
@testable import PressayCore

final class TextProcessingTests: XCTestCase {
    func testCuratedVocabularyRepairsCodingAndSlackTerms() {
        let entries = VocabularyParser.parse(CuratedVocabulary.source)
        let source = "Send a slack message with the git hub p r link. Use swift ui, swift data, core ml, and fluid audio on mac os. Update package json."

        XCTAssertEqual(
            VocabularyParser.normalize(source, entries: entries),
            "Send a Slack message with the GitHub PR link. Use SwiftUI, SwiftData, Core ML, and FluidAudio on macOS. Update package.json."
        )
    }

    func testCuratedVocabularyFixesAuditedMishearingsOnly() {
        let entries = VocabularyParser.parse(CuratedVocabulary.source)
        XCTAssertEqual(
            VocabularyParser.normalize("kimmy says the cloud code docs changed", entries: entries),
            "Kimi says the Claude Code docs changed"
        )
        XCTAssertEqual(
            VocabularyParser.normalize("he is actually jewish", entries: entries),
            "he is actually jewish"
        )
    }

    func testCuratedVocabularyIsUniqueAndExcludesAmbiguousEnglishWords() {
        let entries = VocabularyParser.parse(CuratedVocabulary.source)
        let preferred = entries.map { $0.preferred.lowercased() }

        XCTAssertGreaterThan(entries.count, 20)
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

    func testSkipsCapitalizationForTerminals() {
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("ls -la the downloads folder", capitalizeFirstWord: false),
            "ls -la the downloads folder"
        )
        XCTAssertTrue(DeterministicPromptCleaner.terminalBundleIDs.contains("com.mitchellh.ghostty"))
    }

    func testCollapsesStuttersButKeepsLegitimateDoubles() {
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("starting at WhisperKit WhisperKit with no more than 4 attempts"),
            "Starting at WhisperKit with no more than 4 attempts"
        )
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("Open the SwiftUI SwiftUI SwiftUI docs"),
            "Open the SwiftUI docs"
        )
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("Fix it so that that one also gets the minimum"),
            "Fix it so that that one also gets the minimum"
        )
    }

    func testCleanerPreservesMeaningBearingHedges() {
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("It looks like some kind of plug-in system."),
            "It looks like some kind of plug-in system."
        )
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("The feel says this is sort of a sharp sound."),
            "The feel says this is sort of a sharp sound."
        )
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("Do you know if the cache is warm?"),
            "Do you know if the cache is warm?"
        )
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

    func testValidatorProtectsSingleLetterModelIdentifiers() {
        let validator = ProtectedTokenValidator()
        XCTAssertTrue(ProtectedTokenValidator.protectedTokens(
            in: "Add Kimi K3 to the model list.", vocabulary: []
        ).contains("K3"))
        XCTAssertFalse(validator.validate(
            source: "Add Kimi K3 to the model list.",
            candidate: "Add Kimi K2 to the model list.",
            vocabulary: []
        ).isValid)
        XCTAssertTrue(validator.validate(
            source: "Add Kimi K3 to the model list.",
            candidate: "Please add Kimi K3 to the model list.",
            vocabulary: []
        ).isValid)
    }

    func testValidatorAcceptsNegationExpansion() {
        let validator = ProtectedTokenValidator()
        let expanded = validator.validate(
            source: "I don't want to break the existing setup.",
            candidate: "I do not want to break the existing setup.",
            vocabulary: []
        )
        XCTAssertTrue(expanded.isValid, expanded.reason ?? "")
        let contracted = validator.validate(
            source: "We cannot ship this week.",
            candidate: "We can't ship this week.",
            vocabulary: []
        )
        XCTAssertTrue(contracted.isValid, contracted.reason ?? "")
    }

    func testValidatorStillRejectsDroppedNegation() {
        let validator = ProtectedTokenValidator()
        XCTAssertFalse(validator.validate(
            source: "I don't want to break the existing setup.",
            candidate: "I want to break the existing setup.",
            vocabulary: []
        ).isValid)
        XCTAssertFalse(validator.validate(
            source: "Don't touch the config file.",
            candidate: "Do nothing with the config file.",
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

    /// The clipped-onset case: the mic opened mid-word, so speech starts at
    /// sample 0 and there is no acoustic lead-in to keep.
    func testSpeechStartingAtSampleZeroGetsSyntheticLeadIn() throws {
        let speech = [Float](repeating: 0.04, count: 32_000)
        let trimmed = try AudioTrimmer.trim(speech)
        // 250 ms at 16 kHz prepended, and the pad really is silence.
        XCTAssertEqual(trimmed.count, speech.count + 4_000)
        XCTAssertEqual(trimmed[0..<4_000].max(), 0)
        XCTAssertEqual(trimmed[4_000], 0.04)
    }

    /// A clip that already carries its full lead-in must not be padded again.
    func testAmpleLeadInIsNotPaddedFurther() throws {
        let silence = [Float](repeating: 0, count: 16_000)
        let speech = [Float](repeating: 0.04, count: 32_000)
        let trimmed = try AudioTrimmer.trim(silence + speech + silence)
        XCTAssertEqual(trimmed.count, speech.count + 8_000)
    }

    /// The guard's job is to stop the cue being mistaken for the speech onset,
    /// so the clip anchors on the words rather than on the tone.
    func testEarconIsNotMistakenForTheSpeechOnset() throws {
        let cue = [Float](repeating: 0.05, count: 2_400) // 150 ms tone
        let gap = [Float](repeating: 0, count: 1_600)
        let speech = [Float](repeating: 0.04, count: 32_000)
        let clip = cue + gap + speech

        let guarded = try AudioTrimmer.trim(clip, earconGuard: 0..<2_400)
        let unguarded = try AudioTrimmer.trim(clip)
        // Unguarded, the tone is the onset and drags the whole head of the clip
        // in; guarded, the anchor moves to the speech.
        XCTAssertLessThan(guarded.count, unguarded.count)
        XCTAssertGreaterThanOrEqual(guarded.count, speech.count)
    }

    /// A near-instant warm start actively encourages talking over the cue. That
    /// speech must survive — cutting to the guard's end used to discard it,
    /// which is the exact clipping this whole change exists to remove.
    func testSpeechStartingDuringTheEarconIsNotDiscarded() throws {
        let cueOverSpeech = [Float](repeating: 0.05, count: 2_400)
        let speech = [Float](repeating: 0.04, count: 32_000)
        let trimmed = try AudioTrimmer.trim(
            cueOverSpeech + speech,
            earconGuard: 0..<2_400
        )
        // Every speech sample is still present; nothing was cut to the guard.
        XCTAssertGreaterThanOrEqual(trimmed.count, speech.count)
    }

    /// If the pre-roll caught a real onset before the cue, that audio is worth
    /// more than a clean tone — keep it.
    func testSpeechBeforeTheEarconSurvives() throws {
        let early = [Float](repeating: 0.04, count: 3_200)
        let cue = [Float](repeating: 0.05, count: 2_400)
        let speech = [Float](repeating: 0.04, count: 32_000)
        let trimmed = try AudioTrimmer.trim(
            early + cue + speech,
            earconGuard: 3_200..<5_600
        )
        XCTAssertGreaterThanOrEqual(trimmed.count, early.count + cue.count + speech.count)
    }

    /// Pressing the key and saying nothing is silence, not a transcript of the cue.
    func testCueAloneIsRejectedAsSilence() {
        let cue = [Float](repeating: 0.05, count: 2_400)
        let quiet = [Float](repeating: 0, count: 16_000)
        XCTAssertThrowsError(
            try AudioTrimmer.trim(cue + quiet, earconGuard: 0..<2_400)
        ) { error in
            guard case PressayError.silence = error else {
                return XCTFail("expected .silence, got \(error)")
            }
        }
    }

    /// The guard is derived from a wall-clock duration, so it can overrun the
    /// clip. Clamping must keep the slice in bounds rather than trapping.
    func testEarconGuardBeyondTheClipDoesNotCrash() {
        let speech = [Float](repeating: 0.04, count: 32_000)
        XCTAssertThrowsError(
            try AudioTrimmer.trim(speech, earconGuard: 0..<999_999)
        ) { error in
            guard case PressayError.silence = error else {
                return XCTFail("expected .silence, got \(error)")
            }
        }
    }

    func testEmptyEarconGuardBehavesLikeNoGuard() throws {
        let speech = [Float](repeating: 0.04, count: 32_000)
        let guarded = try AudioTrimmer.trim(speech, earconGuard: 5_000..<5_000)
        let plain = try AudioTrimmer.trim(speech)
        XCTAssertEqual(guarded.count, plain.count)
    }

    func testNegativeEarconGuardIsClamped() throws {
        let speech = [Float](repeating: 0.04, count: 32_000)
        let trimmed = try AudioTrimmer.trim(speech, earconGuard: -500..<0)
        XCTAssertEqual(trimmed.count, speech.count + 4_000)
    }

    /// A guard sitting past the speech must not drag `start` beyond `end`.
    func testGuardAfterTheSpeechDoesNotInvertTheSlice() throws {
        let speech = [Float](repeating: 0.04, count: 8_000)
        let tail = [Float](repeating: 0, count: 24_000)
        let trimmed = try AudioTrimmer.trim(speech + tail, earconGuard: 20_000..<24_000)
        XCTAssertFalse(trimmed.isEmpty)
        XCTAssertEqual(trimmed.max(), 0.04)
    }

    func testProcessingPolicyKeepsNormalPathFastAndAllowsLongPrompts() {
        XCTAssertEqual(DictationProcessingPolicy.asrTimeout(duration: 10), 1.85)
        XCTAssertGreaterThan(DictationProcessingPolicy.asrTimeout(duration: 110), 10)
    }
}
