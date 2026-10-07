import XCTest
@testable import PressayCore

final class PhoneticVocabularyMatcherTests: XCTestCase {
    private let entries = VocabularyParser.parse("""
    Supabase
    Grokbot
    Codex
    Scooper
    Tailwind
    Cognito
    Deepgram
    Polymarket
    RunPod <= rumpod
    Core ML
    Claude Code
    CLAUDE.md
    """)

    private func correct(_ text: String) -> String {
        PhoneticVocabularyMatcher.correct(text, entries: entries)
    }

    func testFixesMishearingsNoAliasLists() {
        // All observed in real dictation history.
        XCTAssertEqual(correct("the data in Superbase is stale"), "the data in Supabase is stale")
        XCTAssertEqual(correct("I gave it to Grockpot."), "I gave it to Grokbot.")
        XCTAssertEqual(correct("try DeepGrim instead"), "try Deepgram instead")
        XCTAssertEqual(correct("Polymark, again"), "Polymarket, again")
        XCTAssertEqual(correct("both PolyMarkets"), "both Polymarkets")
        // The "s" here is part of the match, not a plural (learned in history).
        XCTAssertEqual(correct("ask codecs"), "ask Codex")
    }

    func testLeavesNearbyRealWordsAlone() {
        // Each of these matched a term under looser gates during the replay.
        for text in [
            "search the codebase", "flights to Singapore", "caffeinate the Mac",
            "a toolkit for Trinidad", "the timeframe is fine", "Croatian food",
            "she went to Cornell", "Corman said",
        ] {
            XCTAssertEqual(correct(text), text)
        }
    }

    func testLeavesAcronymsIdentifiersAndAddressesAlone() {
        for text in [
            "SUPERBASE", "superbase.com", "me@superbase", "super-base", "superbase2",
            "src/superbase", "Superbase's",
        ] {
            XCTAssertEqual(correct(text), text)
        }
    }

    func testRunTogetherMultiWordTermsNeedAnExactKey() {
        XCTAssertEqual(correct("ask Clotcode"), "ask Claude Code")
        XCTAssertEqual(correct("ask Claudecode"), "ask Claude Code")
    }

    func testCombiningMarksAreWordCharacters() {
        let text = "e\u{301}Superbase and Superbase\u{301}x"
        XCTAssertEqual(correct(text), text)
    }

    func testSameTermInTwoCasingsIsNotATie() {
        let both = VocabularyParser.parse("Supabase") + [.init(preferred: "supabase")]
        XCTAssertEqual(PhoneticVocabularyMatcher.correct("Superbase", entries: both), "Supabase")
    }

    func testAmbiguousMatchesAreSkipped() {
        let tied = VocabularyParser.parse("Kimbal\nKimbel")
        XCTAssertEqual(PhoneticVocabularyMatcher.correct("Kimbul", entries: tied), "Kimbul")
    }

    func testShortKeysAreNeverMatched() {
        // "Kimmy" keys to KM: too short to tell apart from ordinary speech.
        let short = VocabularyParser.parse("Kimi")
        XCTAssertEqual(PhoneticVocabularyMatcher.correct("Kimmy", entries: short), "Kimmy")
    }

    func testRunsInsideTheCleaner() {
        XCTAssertEqual(
            DeterministicPromptCleaner.clean("um check superbase", vocabulary: entries),
            "Check Supabase")
        XCTAssertEqual(
            DeterministicPromptCleaner.clean(
                "cd superbase", vocabulary: entries, capitalizeFirstWord: false, phoneticFallback: false),
            "cd superbase")
    }
}
