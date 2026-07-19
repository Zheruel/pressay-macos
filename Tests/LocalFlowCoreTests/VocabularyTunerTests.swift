import XCTest
@testable import LocalFlowCore

final class VocabularyTunerTests: XCTestCase {
    private let anchors = [
        "Kimi", "Kimi Code", "Claude Code", "Anthropic", "Wispr Flow", "Claude",
        "Codex", "ChatGPT", "OpenAI", "WhisperKit", "Core ML", "SwiftUI", "SwiftData",
        "FluidAudio", "VS Code", "Node.js", "Next.js", "PostgreSQL", "GitHub", "GitLab",
        "Slack", "Docker", "Markdown", "macOS", "Apple Silicon", "PR", "API", "JSON",
        "RunPod", "SonarCloud", "TL;DR",
    ]

    private func corpusTexts() -> [String] {
        [
            "Can you look at the API for Kimmy? It seems like we got duplicated options. Kimmy only has normal or low.",
            "I would like to use my Kimi code subscription with Cloud Code. Don't break any of the Cloud Code functionality.",
            "I have got an Akimi plan, a Codex plan, and an Entropic plan. Akimi is great, Entropic too.",
            "I don't know how Rumpod works, but you can find out by googling. Rumpod has GPUs.",
            "something like Whisperflow. It runs faster than Whisperflow cause it's local. Whisperflow is nice.",
            "He is actually Jewish. Generate the Jewish music video, traditional Jewish dance.",
            "I want you to check something regarding SoonerCloud. We have it set up on a bunch of repositories. SoonerCloud works well.",
            "I'm talking about the shadow strategy that we have for TWC. The TWC strategy.",
            "I already had the Bumpar plan once. The Bumpar plan.",
            "give me a TLDR. a TLDR of the changes. TLDR please. TLDR.",
        ]
    }

    func testMinerFiltersEnglishAndFindsUnknownTerms() {
        let candidates = VocabularyTuner.candidates(in: corpusTexts(), anchors: anchors)
        let terms = Set(candidates.map(\.term))
        for expected in ["Kimmy", "Akimi", "Entropic", "Rumpod", "Whisperflow", "Bumpar", "SoonerCloud", "TWC", "TLDR", "Cloud Code"] {
            XCTAssertTrue(terms.contains(expected), "missing candidate \(expected)")
        }
        XCTAssertFalse(terms.contains("Jewish"), "ordinary English must be filtered")
        XCTAssertFalse(terms.contains("makes"))
        XCTAssertFalse(terms.contains("actually"))
    }

    func testDeterministicRulesMatchCorpusValidatedSet() {
        let rules = VocabularyTuner.deterministicRules(
            candidates: VocabularyTuner.candidates(in: corpusTexts(), anchors: anchors),
            anchors: anchors
        )
        let byHeard = Dictionary(uniqueKeysWithValues: rules.map { ($0.heard.lowercased(), $0.preferred) })
        XCTAssertEqual(byHeard["entropic"], "Anthropic")
        XCTAssertEqual(byHeard["rumpod"], "RunPod")
        XCTAssertEqual(byHeard["cloud code"], "Claude Code")
        XCTAssertEqual(byHeard["whisperflow"], "Wispr Flow")
        XCTAssertEqual(byHeard["tldr"], "TL;DR")
        // User-confirmed: "SoonerCloud" in the corpus is SonarCloud the SaaS.
        XCTAssertEqual(byHeard["soonercloud"], "SonarCloud")
        for rejected in ["Jewish", "Bumpar", "TWC", "Kimi", "makes"] {
            XCTAssertNil(byHeard[rejected.lowercased()], "\(rejected) must not produce a rule")
        }
    }

    func testAnchorFilteredLLMRulesKeepOnlyAnchorTargets() {
        let rules = VocabularyTuner.anchorFilteredRules(
            findings: [
                (heard: "Kimmy", meant: "Kimi"),
                (heard: "Akimi", meant: "Kimi"),
                (heard: "SoonerCloud", meant: "SonarCloud"),
                (heard: "OGG", meant: "OG"),
            ],
            anchors: anchors,
            counts: ["Kimmy": 5, "Akimi": 2]
        )
        let byHeard = Dictionary(uniqueKeysWithValues: rules.map { ($0.heard, $0.preferred) })
        XCTAssertEqual(byHeard["Kimmy"], "Kimi")
        XCTAssertEqual(byHeard["Akimi"], "Kimi")
        XCTAssertNil(byHeard["OGG"], "non-anchor corrections must be rejected")
        XCTAssertNotNil(byHeard["SoonerCloud"], "SonarCloud is an anchor here, so it is kept")
    }

    func testAnchorCollisionIsSkipped() {
        // SwiftData and SwiftUI share a phonetic key; a candidate near both
        // must not be arbitrarily assigned to either.
        let rules = VocabularyTuner.deterministicRules(
            candidates: [TunerCandidate(term: "swiftdayta", count: 3, excerpt: "x")],
            anchors: ["SwiftUI", "SwiftData"]
        )
        XCTAssertTrue(rules.isEmpty)
    }

    func testInflectedEnglishWordsAreNotCandidates() {
        XCTAssertFalse(VocabularyTuner.isCandidateTerm("darker"))
        XCTAssertFalse(VocabularyTuner.isCandidateTerm("cloned"))
        XCTAssertFalse(VocabularyTuner.isCandidateTerm("running"))
        XCTAssertTrue(VocabularyTuner.isCandidateTerm("Whisperflow"))
        XCTAssertTrue(VocabularyTuner.isCandidateTerm("Rumpod"))
    }

    func testIncrementalRulesLearnFromSingleOccurrence() {
        let rules = VocabularyTuner.incrementalRules(
            for: "Can you check the Rumpod dashboard for me?",
            anchors: ["RunPod", "Claude Code"]
        )
        XCTAssertEqual(rules.map(\.heard), ["Rumpod"])
        XCTAssertEqual(rules.map(\.preferred), ["RunPod"])
        XCTAssertTrue(VocabularyTuner.incrementalRules(
            for: "Make the design darker and clone the repository",
            anchors: ["Docker", "Claude"]
        ).isEmpty)
    }

    func testTokensKeepIdentifiersWhole() {
        let tokens = VocabularyTuner.tokens(in: "Don't break K3 or node.js, it's K3.1M, ok?")
        XCTAssertTrue(tokens.contains("Don't"))
        XCTAssertTrue(tokens.contains("K3"))
        XCTAssertTrue(tokens.contains("node.js"))
    }
}
