import XCTest
@testable import PressayCore

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

    func testIncrementalRulesRequireExactPhoneticKeys() {
        // Distance-0 mishearings still learn from a single dictation.
        let exact = VocabularyTuner.incrementalRules(
            for: "something like Whisperflow but local",
            anchors: ["Wispr Flow", "RunPod"]
        )
        XCTAssertEqual(exact.map(\.heard), ["Whisperflow"])
        XCTAssertEqual(exact.map(\.preferred), ["Wispr Flow"])

        // Distance-1 ("Rumpod" → RunPod) is real but needs recurrence; the
        // daily pass learns it, the single-sighting path must not.
        XCTAssertTrue(VocabularyTuner.incrementalRules(
            for: "Can you check the Rumpod dashboard for me?",
            anchors: ["RunPod", "Claude Code"]
        ).isEmpty)
        XCTAssertTrue(VocabularyTuner.incrementalRules(
            for: "Make the design darker and clone the repository",
            anchors: ["Docker", "Claude"]
        ).isEmpty)
    }

    // MARK: - Regression: false positives learned on real machines

    func testOrdinaryEnglishWordsAreNeverCandidates() {
        // Each of these was live in a user's learned rules: mix → macOS,
        // mockups → macOS, correction → Markdown, colleagues → Codex.
        for word in ["mix", "mockups", "mockup", "correction", "colleagues"] {
            XCTAssertFalse(VocabularyTuner.isCandidateTerm(word), "\(word) is ordinary English")
        }
        let texts = [
            "Let's mix the correction into the mockups my colleagues made.",
            "Another mix of correction notes for the mockups from colleagues.",
        ]
        let candidates = VocabularyTuner.candidates(in: texts, anchors: anchors)
        XCTAssertTrue(candidates.isEmpty, "unexpected candidates: \(candidates.map(\.term))")
        XCTAssertTrue(VocabularyTuner.deterministicRules(candidates: candidates, anchors: anchors).isEmpty)
    }

    func testShortPhoneticKeysCannotMatchEvenAsForcedCandidates() {
        // Defense in depth: even if the word list misses a term, a
        // three-consonant key ("mix" → MKS ≡ macOS) must not match.
        let forced = [TunerCandidate(term: "mix", count: 5, excerpt: "x")]
        XCTAssertTrue(VocabularyTuner.deterministicRules(candidates: forced, anchors: anchors).isEmpty)
        XCTAssertEqual(
            VocabularyTuner.deterministicRules(candidates: forced, anchors: anchors, config: .legacy)
                .map(\.preferred),
            ["macOS"],
            "legacy config must reproduce the regression class the fix targets"
        )
    }

    func testFuzzyMatchesNeedRecurrenceScaledEvidence() {
        let once = [TunerCandidate(term: "Entropic", count: 1, excerpt: "x")]
        let twice = [TunerCandidate(term: "Entropic", count: 2, excerpt: "x")]
        XCTAssertTrue(VocabularyTuner.deterministicRules(candidates: once, anchors: anchors).isEmpty)
        XCTAssertEqual(
            VocabularyTuner.deterministicRules(candidates: twice, anchors: anchors).map(\.preferred),
            ["Anthropic"]
        )
        // Distance-0 promotes from a single sighting.
        let exactOnce = [TunerCandidate(term: "Whisperflow", count: 1, excerpt: "x")]
        XCTAssertEqual(
            VocabularyTuner.deterministicRules(candidates: exactOnce, anchors: anchors).map(\.preferred),
            ["Wispr Flow"]
        )
    }

    func testCloudMDMatchesClaudeMarkdownFileWhenAnchored() {
        // "CloudMD" is a mishearing of "CLAUDE.md"; with the file in the
        // anchors it exact-matches there instead of snapping to Claude Code.
        let rules = VocabularyTuner.deterministicRules(
            candidates: [TunerCandidate(term: "CloudMD", count: 1, excerpt: "x")],
            anchors: anchors + ["CLAUDE.md"]
        )
        XCTAssertEqual(rules.map(\.preferred), ["CLAUDE.md"])
    }

    func testJudgeWorthyKeepsAcousticNeighborsAndDropsFarTerms() {
        // Corpus-measured: distance cap 2 keeps 25/26 true LLM-judge finds
        // while dropping ~60% of candidates (guaranteed rejections).
        let candidates = [
            "CloudCode", "TLDA", "Sona Cloud", "SornCloud", "Kimmy",
            "Polymarket", "Buenos Aires", "Fjordvik",
        ].map { TunerCandidate(term: $0, count: 1, excerpt: "x") }
        let worthy = Set(
            VocabularyTuner.judgeWorthy(candidates: candidates, anchors: anchors + ["SonarCloud", "CLAUDE.md"])
                .map(\.term)
        )
        for kept in ["CloudCode", "TLDA", "Sona Cloud", "SornCloud", "Kimmy"] {
            XCTAssertTrue(worthy.contains(kept), "\(kept) is in acoustic range of an anchor")
        }
        for dropped in ["Polymarket", "Buenos Aires"] {
            XCTAssertFalse(worthy.contains(dropped), "\(dropped) has no anchor in range")
        }
    }

    func testMigrationDropsDetRulesAndKeepsK3() {
        XCTAssertFalse(LearnedRuleMigration.survivesV1(source: LearnedRule.Source.det.rawValue))
        XCTAssertTrue(LearnedRuleMigration.survivesV1(source: LearnedRule.Source.k3.rawValue))
    }

    func testRetentionExpiresOnlyLongUnusedRules() {
        let now = Date()
        let day: TimeInterval = 24 * 3_600
        XCTAssertFalse(LearnedRuleRetention.isExpired(lastSeen: now.addingTimeInterval(-29 * day), now: now))
        XCTAssertFalse(LearnedRuleRetention.isExpired(lastSeen: now.addingTimeInterval(-89 * day), now: now))
        XCTAssertTrue(LearnedRuleRetention.isExpired(lastSeen: now.addingTimeInterval(-91 * day), now: now))
    }

    func testTokensKeepIdentifiersWhole() {
        let tokens = VocabularyTuner.tokens(in: "Don't break K3 or node.js, it's K3.1M, ok?")
        XCTAssertTrue(tokens.contains("Don't"))
        XCTAssertTrue(tokens.contains("K3"))
        XCTAssertTrue(tokens.contains("node.js"))
    }
}
