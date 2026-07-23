import Foundation

public struct TunerCandidate: Equatable, Sendable {
    public let term: String
    public let count: Int
    public let excerpt: String

    public init(term: String, count: Int, excerpt: String) {
        self.term = term
        self.count = count
        self.excerpt = excerpt
    }
}

public struct LearnedRule: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case det
        case k3
    }

    public let heard: String
    public let preferred: String
    public let count: Int
    public let source: Source

    public init(heard: String, preferred: String, count: Int, source: Source) {
        self.heard = heard
        self.preferred = preferred
        self.count = count
        self.source = source
    }
}

/// Derives vocabulary alias rules from transcripts. Conservative by design:
/// ordinary English is filtered out and matches must land on anchor terms.
public enum VocabularyTuner {
    /// Recurring unigram/bigram terms that are not plain English. Bigrams of
    /// two ordinary words survive only when the phrase exactly keys to an
    /// anchor — how "cloud code" (plain English, part by part) can be learned
    /// as a "Claude Code" mishearing.
    public static func candidates(
        in texts: [String],
        minimumCount: Int = 2,
        anchors: [String] = []
    ) -> [TunerCandidate] {
        var unigramCounts: [String: Int] = [:]
        var bigramCounts: [String: Int] = [:]
        var excerpts: [String: String] = [:]
        var order: [String: Int] = [:]
        let anchorKeys = Set(anchors.map { PhoneticKey.key($0) })

        func record(_ term: String, in counts: inout [String: Int], context: String) {
            counts[term, default: 0] += 1
            if order[term] == nil { order[term] = order.count }
            if excerpts[term] == nil { excerpts[term] = context }
        }

        for text in texts {
            let words = tokens(in: text)
            for (index, word) in words.enumerated() {
                if isCandidateTerm(word) {
                    record(word, in: &unigramCounts, context: context(around: index, in: words))
                }
                if index > 0 {
                    let bigram = "\(words[index - 1]) \(word)"
                    if bigramCandidate(words[index - 1], word, anchorKeys: anchorKeys) {
                        record(bigram, in: &bigramCounts, context: context(around: index - 1, in: words))
                    }
                }
            }
        }

        let merged = unigramCounts.merging(bigramCounts) { $0 + $1 }
        return merged
            .filter { $0.value >= minimumCount }
            .sorted { ($0.value, order[$0.key] ?? 0) > ($1.value, order[$1.key] ?? 0) }
            .map { TunerCandidate(term: $0.key, count: $0.value, excerpt: excerpts[$0.key] ?? "") }
    }

    static func tolerance(forKeyLength length: Int) -> Int {
        if length <= 3 { return 0 }
        if length <= 7 { return 1 }
        return 2
    }

    /// Gates for the deterministic matcher. `.fixed` is the shipping default;
    /// `.legacy` reproduces the pre-fix behavior so the bench can replay both
    /// side by side; `.exact` is the per-dictation profile where a single
    /// sighting is all the evidence there will ever be.
    public struct DetConfig: Sendable {
        /// Shortest phonetic key eligible for matching. Three-consonant keys
        /// ("mix" → MKS) collide with anchors ("macOS" → MKS) too easily.
        public var minimumKeyLength: Int
        /// Caps the length-based tolerance table; 0 means exact keys only.
        public var toleranceCap: Int
        /// Fuzzier matches need more recurrence: `count >= distance + 1`.
        public var scalesEvidenceWithDistance: Bool

        public static let legacy = DetConfig(
            minimumKeyLength: 3, toleranceCap: 2, scalesEvidenceWithDistance: false
        )
        public static let fixed = DetConfig(
            minimumKeyLength: 4, toleranceCap: 2, scalesEvidenceWithDistance: true
        )
        public static let exact = DetConfig(
            minimumKeyLength: 4, toleranceCap: 0, scalesEvidenceWithDistance: true
        )
    }

    /// Collision-ties between two anchors are skipped, and bigrams of ordinary
    /// words ("commit code") require exact phrase keys — they collide with
    /// anchors at distance 1, which unigrams ("entropic") are allowed.
    public static func deterministicRules(
        candidates: [TunerCandidate],
        anchors: [String],
        config: DetConfig = .fixed
    ) -> [LearnedRule] {
        let anchorKeys = anchors.map { ($0, PhoneticKey.key($0)) }
        let anchorFolds = Set(anchors.map { $0.lowercased() })
        var rules: [LearnedRule] = []
        for candidate in candidates {
            let fold = candidate.term.lowercased()
            guard !anchorFolds.contains(fold) else { continue }
            let key = PhoneticKey.key(candidate.term)
            guard key.count >= config.minimumKeyLength else { continue }
            let distances = anchorKeys
                .map { (anchor: $0.0, distance: PhoneticKey.distance(key, $0.1)) }
                .sorted { $0.distance < $1.distance }
            guard let best = distances.first,
                  distances.count < 2 || distances[1].distance > best.distance else { continue }
            let limit = candidate.term.contains(" ")
                ? 0
                : min(tolerance(forKeyLength: key.count), config.toleranceCap)
            guard best.distance <= limit else { continue }
            if config.scalesEvidenceWithDistance {
                guard candidate.count >= best.distance + 1 else { continue }
            }
            rules.append(LearnedRule(
                heard: candidate.term,
                preferred: best.anchor,
                count: candidate.count,
                source: .det
            ))
        }
        return rules
    }

    /// Single-transcript rules for the dictation path. One sighting is the
    /// only evidence available here, so only exact phonetic keys qualify;
    /// fuzzy mishearings wait for the daily pass, where recurrence across the
    /// 30-day history can meet the distance-scaled evidence bar.
    public static func incrementalRules(for text: String, anchors: [String]) -> [LearnedRule] {
        let fresh = candidates(in: [text], minimumCount: 1, anchors: anchors)
        guard !fresh.isEmpty else { return [] }
        return deterministicRules(candidates: fresh, anchors: anchors, config: .exact)
    }

    /// Candidates worth sending to the LLM judge: within phonetic reach of
    /// some anchor. A finding can only be accepted when `meant` is an anchor,
    /// so terms with no anchor in acoustic range (project names, foreign
    /// words, jargon) are guaranteed rejections — sending them wastes tokens.
    public static func judgeWorthy(
        candidates: [TunerCandidate],
        anchors: [String],
        maxDistance: Int = 2
    ) -> [TunerCandidate] {
        let anchorKeys = anchors.map { PhoneticKey.key($0) }
        return candidates.filter { candidate in
            let key = PhoneticKey.key(candidate.term)
            guard !key.isEmpty else { return false }
            return anchorKeys.contains { PhoneticKey.distance(key, $0) <= maxDistance }
        }
    }

    /// LLM findings are accepted only when the correction lands on an anchor
    /// term (curated, user-added, or previously learned).
    public static func anchorFilteredRules(
        findings: [(heard: String, meant: String)],
        anchors: [String],
        counts: [String: Int]
    ) -> [LearnedRule] {
        let anchorFolds = Set(anchors.map { $0.lowercased() })
        return findings.compactMap { finding in
            let heard = finding.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let meant = finding.meant.trimmingCharacters(in: .whitespacesAndNewlines)
            // A heard term that is itself an anchor must never become a rule:
            // it would rewrite the user's own vocabulary (same guard as the
            // deterministic path).
            guard !heard.isEmpty,
                  anchorFolds.contains(meant.lowercased()),
                  !anchorFolds.contains(heard.lowercased()) else { return nil }
            return LearnedRule(
                heard: heard,
                preferred: meant,
                count: counts[heard] ?? 1,
                source: .k3
            )
        }
    }

    // MARK: - Tokenizing and filtering

    static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'.+-"))
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for character in text {
            let continues = character.isLetter
                || (character.isNumber && !current.isEmpty)
                || ((character == "'" || character == "." || character == "+" || character == "-") && !current.isEmpty)
            if continues {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    static func isCandidateTerm(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        let fold = word.lowercased()
        return !EnglishWordList.contains(fold) && !hasEnglishStem(fold)
    }

    /// The word list stores base forms; "darker" and "cloned" must count as
    /// English or they become phonetic-match candidates ("Docker", "Claude").
    static func hasEnglishStem(_ fold: String) -> Bool {
        for suffix in ["s", "es", "d", "ed", "ing", "er", "est", "ly"] {
            guard fold.hasSuffix(suffix), fold.count - suffix.count >= 3 else { continue }
            let stem = String(fold.dropLast(suffix.count))
            if EnglishWordList.contains(stem) || EnglishWordList.contains(stem + "e") {
                return true
            }
            if stem.count >= 4, stem.last == stem.dropLast().last,
               EnglishWordList.contains(String(stem.dropLast())) {
                return true
            }
        }
        for suffix in ["ies", "ied"] where fold.hasSuffix(suffix) && fold.count - suffix.count >= 2 {
            if EnglishWordList.contains(String(fold.dropLast(suffix.count)) + "y") {
                return true
            }
        }
        return false
    }

    static func bigramCandidate(_ first: String, _ second: String, anchorKeys: Set<String>) -> Bool {
        let combined = first + second
        guard combined.count >= 3 else { return false }
        if isCandidateTerm(first) || isCandidateTerm(second) { return true }
        let key = PhoneticKey.key("\(first) \(second)")
        guard key.count >= 4 else { return false }
        return anchorKeys.contains(key)
    }

    private static func context(around index: Int, in words: [String]) -> String {
        let lower = max(0, index - 6)
        let upper = min(words.count, index + 7)
        return words[lower..<upper].joined(separator: " ")
    }
}
