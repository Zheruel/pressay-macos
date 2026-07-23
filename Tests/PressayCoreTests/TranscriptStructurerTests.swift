import XCTest
@testable import PressayCore

final class TranscriptStructurerTests: XCTestCase {
    private func fixtures() -> [String] {
        [
            "Can you look at the parser? It crashes when the input is empty. I think the tokenizer is at fault. We should add a regression test. Also we need to update the changelog before the release goes out.",
            "so the idea here is that we have something like a menu bar app and I think we could do three things. One, we could have settings. Two, we could add a history window. Three, we could ship a CLI.",
            "first, update the manifest. second, rerun the benchmark. finally, compare the results against the stored baseline. that should give us enough signal to decide.",
            "check the parser in node.js and the config in package.json e.g. the timeout values. those should match the defaults we agreed on yesterday in the review.",
        ]
    }

    func testShortInputPassesThroughUntouched() {
        let text = "just a quick note"
        XCTAssertEqual(TranscriptStructurer.structure(text), text)
    }

    func testSpokenStructureIsNeverMerged() {
        let text = """
        We shipped the first milestone yesterday and the demo went well overall.

        - keep the overlay
        - drop the sound cue and simplify settings for the next release cycle
        """
        XCTAssertEqual(TranscriptStructurer.structure(text), text)
    }

    func testAppendsTerminalPunctuationAndCapitalizes() {
        let text = "the parser crashes when the input is empty. we should add a regression test before shipping anything else to the users"
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.hasPrefix("The parser"))
        XCTAssertTrue(structured.contains("We should add"))
        XCTAssertTrue(structured.hasSuffix("."))
    }

    func testAbbreviationsAndDottedIdentifiersDoNotSplitSentences() {
        let sentences = TranscriptStructurer.split(
            intoSentences: "Check the config in node.js e.g. the timeout values. Those should match."
        )
        XCTAssertEqual(sentences.count, 2)
        XCTAssertTrue(sentences[0].contains("e.g. the timeout"))
    }

    func testSpokenEnumerationBecomesBulletList() {
        let text = "I think we could do three things. First, we could have settings. Second, we could add a history window. Finally, we could ship a CLI."
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.contains("- We could have settings."))
        XCTAssertTrue(structured.contains("- We could add a history window."))
        XCTAssertTrue(structured.contains("- We could ship a CLI."))
    }

    func testFirstOfAllEnumerationsBecomeLists() {
        let text = "I would love to make this a model selection I can do in the settings. First of all, is this even supported by the runtime? Second of all, how can I actually do this without breaking anything?"
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.contains("- Is this even supported by the runtime?"), structured)
        XCTAssertTrue(structured.contains("- How can I actually do this"), structured)
    }

    func testOrdinalSubjectsKeepTheirMarkerText() {
        // "Step one" is the grammatical subject; stripping it would leave
        // "Should definitely be…". The item keeps its full sentence.
        let text = "Here is how I want to tackle the whole migration project. Step one should definitely be just evaluate and report. Step two should be the actual refactor once we agree."
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.contains("- Step one should definitely be just evaluate and report."), structured)
        XCTAssertTrue(structured.contains("- Step two should be the actual refactor once we agree."), structured)
    }

    func testBareThenRunsDoNotBecomeLists() {
        let text = "We start the recorder when the key goes down. Then we stop it on release. Then we transcribe the clip and insert the text into the field."
        XCTAssertFalse(TranscriptStructurer.structure(text).contains("- "))
    }

    func testParagraphBreaksOnDiscourseMarkers() {
        let text = "The parser crashes when the input is empty. I think the tokenizer is at fault. Also we need to update the changelog before the release goes out to everyone."
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.contains("\n\nAlso we need to update"))
    }

    func testLongProseIsSplitIntoParagraphs() {
        let sentence = "This sentence pads the paragraph with enough words to matter."
        let text = Array(repeating: sentence, count: 9).joined(separator: " ")
        let paragraphs = TranscriptStructurer.structure(text).components(separatedBy: "\n\n")
        XCTAssertGreaterThan(paragraphs.count, 1)
    }

    func testRepairsPunctuationlessTranscript() {
        let text = "we looked at the benchmark results this morning and the latency numbers look fine on the whole and then we started digging into the vocabulary tuner because some of the learned rules were clearly wrong for ordinary words"
        let structured = TranscriptStructurer.structure(text)
        XCTAssertTrue(structured.contains(". And then"), "expected a repaired sentence break: \(structured)")
    }

    func testRunOnAfterParagraphSplitIsRepairedAndIdempotent() {
        // Corpus-found regression: a punctuated first half followed by an
        // "Also" paragraph whose long unpunctuated tail hides an "and then".
        // The break decision must be local to the connector, or the first
        // pass (whole text) and second pass (split paragraph) disagree.
        let text = "The parser crashes when the input is empty. I think the tokenizer is at fault. Also look at the other reports and maybe the price of rebuilding the whole module from scratch given what we know and then in general write me a concise clear report about it"
        let once = TranscriptStructurer.structure(text)
        XCTAssertTrue(once.contains(". And then"), "expected a repaired break: \(once)")
        XCTAssertEqual(TranscriptStructurer.structure(once), once)
    }

    func testIdempotentOnFixtures() {
        for text in fixtures() {
            let once = TranscriptStructurer.structure(text)
            XCTAssertEqual(TranscriptStructurer.structure(once), once, "not idempotent for: \(text)")
        }
    }

    func testProtectedTokensAlwaysSurvive() {
        let validator = ProtectedTokenValidator()
        for text in fixtures() {
            let structured = TranscriptStructurer.structure(text)
            let validation = validator.validate(source: text, candidate: structured, vocabulary: [])
            XCTAssertTrue(validation.isValid, "validator failed for: \(text) -> \(validation.missingTokens)")
        }
    }
}
