import Foundation

/// Runtime fallback for vocabulary words the ASR misspelled in a way no alias
/// lists ("Superbase" → Supabase, "Grockpot" → Grokbot). One sighting is all
/// the evidence a dictation has, so every gate errs toward leaving text alone:
/// only single non-English words qualify, the spelling must agree
/// (`VocabularyTuner.spellingAgrees`), the key must be long enough to be distinctive,
/// and the nearest term must be unique and at most one phonetic edit away.
/// Replayed over 4,700 real dictations, looser gates rewrote "codebase" to
/// Codex and "Singapore" to Scooper; these ones did not.
public enum PhoneticVocabularyMatcher {
    /// Letters only, never part of an email, path, domain, hyphenated compound
    /// or identifier with digits; those are deliberate spellings.
    private static let wordRegex = try? NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_./@'’-])\p{L}{3,}(?![\p{L}\p{M}\p{N}_@/'’-])(?!\.\p{L})"#
    )

    static let minimumKeyLength = 4
    static let maximumDistance = 1

    struct Anchor {
        let term: String
        let key: String
        /// Multi-word and acronym terms ("Core ML") sit one edit from too many
        /// names ("Cornell"); they only take exact phonetic matches.
        let exactOnly: Bool
    }

    public static func correct(_ text: String, entries: [VocabularyParser.Entry]) -> String {
        guard let wordRegex, !entries.isEmpty else { return text }
        let known = Set(entries.flatMap { [$0.preferred] + $0.aliases }.map { $0.lowercased() })
        var seen = Set<String>()
        let anchors = entries.compactMap { entry -> Anchor? in
            let term = entry.preferred
            // File names and symbols (CLAUDE.md, .env, TL;DR) are never what a
            // single misheard word meant.
            guard !term.contains(where: { ".;/".contains($0) }),
                  seen.insert(term.lowercased()).inserted else { return nil }
            let key = PhoneticKey.key(String(term.filter(\.isLetter)))
            guard key.count >= minimumKeyLength else { return nil }
            let hasAcronym = term.split(whereSeparator: { !$0.isLetter }).contains {
                $0.count > 1 && $0 == $0.uppercased()
            }
            return Anchor(
                term: term, key: key,
                exactOnly: term.contains(" ") || hasAcronym
            )
        }
        guard !anchors.isEmpty else { return text }

        var result = text
        let matches = wordRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let word = String(result[range])
            guard let replacement = anchor(for: word, anchors: anchors, known: known) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func anchor(for word: String, anchors: [Anchor], known: Set<String>) -> String? {
        let fold = word.lowercased()
        // All-caps tokens are acronyms the speaker spelled out on purpose.
        guard !known.contains(fold),
              word != word.uppercased(),
              VocabularyTuner.isCandidateTerm(word) else { return nil }
        let key = PhoneticKey.key(word)
        guard key.count >= minimumKeyLength else { return nil }
        let tolerance = min(VocabularyTuner.tolerance(forKeyLength: key.count), maximumDistance)
        var best: (anchor: Anchor, distance: Int)?
        var tied = false
        for anchor in anchors where VocabularyTuner.spellingAgrees(heard: word, anchor: anchor.term) {
            let distance = PhoneticKey.distance(key, anchor.key)
            guard distance <= (anchor.exactOnly ? 0 : tolerance) else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (anchor, distance)
                    tied = false
                } else if distance == current.distance {
                    tied = true
                }
            } else {
                best = (anchor, distance)
            }
        }
        guard let best, !tied else { return nil }
        // Keep a plural the speaker said ("PolyMarkets" → "Polymarkets"), but
        // only when the "s" was not itself part of the match ("codecs" → Codex).
        if fold.hasSuffix("s"),
           !"sxz".contains(best.anchor.term.lowercased().last ?? "s"),
           PhoneticKey.distance(PhoneticKey.key(String(word.dropLast())), best.anchor.key) < best.distance {
            return best.anchor.term + "s"
        }
        return best.anchor.term
    }
}
