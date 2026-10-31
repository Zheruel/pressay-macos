import Foundation

/// Runtime fallback for vocabulary words misspelled in a way no alias lists ("Superbase" → Supabase).
/// One sighting is all the evidence, so every gate errs toward leaving text alone. Replayed over 4,700
/// dictations, looser gates rewrote "codebase" → Codex and "Singapore" → Scooper.
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
              VocabularyMatchSafety.isCandidateTerm(word) else { return nil }
        let key = PhoneticKey.key(word)
        guard key.count >= minimumKeyLength else { return nil }
        var best: (anchor: Anchor, distance: Int)?
        var tied = false
        for anchor in anchors where VocabularyMatchSafety.spellingAgrees(heard: word, anchor: anchor.term) {
            let distance = PhoneticKey.distance(key, anchor.key)
            guard distance <= (anchor.exactOnly ? 0 : maximumDistance) else { continue }
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

/// Safety gates for correcting a single word against vocabulary the user supplied.
enum VocabularyMatchSafety {
    static func spellingAgrees(heard: String, anchor: String) -> Bool {
        let heardLetters = heard.lowercased().filter(\.isLetter)
        let anchorLetters = anchor.lowercased().filter(\.isLetter)
        return onset(heardLetters) == onset(anchorLetters)
            && abs(heardLetters.count - anchorLetters.count) <= 2
    }

    /// First two letters, with a silent "h" after the first dropped
    /// ("whisper" ~ "Wispr") and any leading vowel treated alike
    /// ("entropic" ~ "Anthropic").
    static func onset(_ letters: String) -> String {
        var chars = Array(letters)
        if chars.count > 2, chars[1] == "h", chars[0] == "w" { chars.remove(at: 1) }
        guard let first = chars.first else { return "" }
        let head: Character = "aeiou".contains(first) ? "*" : first
        return String(head) + (chars.count > 1 ? String(chars[1]) : "")
    }

    static func isCandidateTerm(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        let fold = word.lowercased()
        return !EnglishWordList.contains(fold) && !hasEnglishStem(fold)
    }

    /// The word list stores base forms; "darker" and "cloned" must count as
    /// English or they become phonetic-match candidates ("Docker", "Claude").
    static func hasEnglishStem(_ fold: String) -> Bool {
        if hasEnglishSuffixStem(fold) { return true }
        // "redeploy", "mispriced", "preset": a prefix on an English word.
        for prefix in ["re", "un", "pre", "mis", "over", "under", "sub", "non", "de"]
        where fold.hasPrefix(prefix) && fold.count - prefix.count >= 3 {
            let stem = String(fold.dropFirst(prefix.count))
            if EnglishWordList.contains(stem) || hasEnglishSuffixStem(stem) { return true }
        }
        return false
    }

    private static func hasEnglishSuffixStem(_ fold: String) -> Bool {
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
}
