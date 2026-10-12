import Foundation

/// A word as typed or transcribed, with its character offsets in the text.
public struct PositionedWord: Equatable, Sendable {
    public let text: String
    /// Character offsets (not UTF-16) into the source string.
    public let range: Range<Int>
}

/// Word-level diff (longest common subsequence) for short texts.
public enum WordDiff {
    public struct Hunk: Equatable, Sendable {
        public let old: Range<Int>
        public let new: Range<Int>
    }

    /// Letter/digit runs keeping inner `'.-+` ("CLAUDE.md", "gpt-6"), trailing punctuation trimmed.
    public static func words(in text: String) -> [PositionedWord] {
        var result: [PositionedWord] = []
        var current = ""
        var start = 0
        func flush(at end: Int) {
            var word = current
            var trimmedEnd = end
            while let last = word.last, "'.-+".contains(last) {
                word.removeLast()
                trimmedEnd -= 1
            }
            if !word.isEmpty { result.append(PositionedWord(text: word, range: start..<trimmedEnd)) }
            current = ""
        }
        for (offset, character) in text.enumerated() {
            let continues = character.isLetter || character.isNumber
                || ("'.-+".contains(character) && !current.isEmpty)
            if continues {
                if current.isEmpty { start = offset }
                current.append(character)
            } else if !current.isEmpty {
                flush(at: offset)
            }
        }
        if !current.isEmpty { flush(at: text.count) }
        return result
    }

    /// Nil when the differing middle is too large to diff cheaply.
    public static func hunks(
        _ a: [String],
        _ b: [String],
        equal: (String, String) -> Bool = { $0 == $1 },
        limit: Int = 400
    ) -> [Hunk]? {
        var prefix = 0
        while prefix < a.count, prefix < b.count, equal(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              equal(a[a.count - 1 - suffix], b[b.count - 1 - suffix]) { suffix += 1 }
        let oldMiddle = Array(a[prefix..<(a.count - suffix)])
        let newMiddle = Array(b[prefix..<(b.count - suffix)])
        if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }
        guard oldMiddle.count <= limit, newMiddle.count <= limit else { return nil }

        let n = oldMiddle.count, m = newMiddle.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = equal(oldMiddle[i], newMiddle[j])
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        var hunkStart: (Int, Int)?
        func close() {
            if let (si, sj) = hunkStart {
                hunks.append(Hunk(old: (prefix + si)..<(prefix + i), new: (prefix + sj)..<(prefix + j)))
                hunkStart = nil
            }
        }
        while i < n || j < m {
            if i < n, j < m, equal(oldMiddle[i], newMiddle[j]) {
                close()
                i += 1; j += 1
            } else {
                if hunkStart == nil { hunkStart = (i, j) }
                if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 } else { i += 1 }
            }
        }
        close()
        return hunks
    }
}

/// One word the user (or the cleanup model) respelled.
public struct VocabularyCorrection: Equatable, Sendable {
    public let heard: String
    public let typed: String
    /// Both spelling and sound agree: safe to apply without asking.
    public let isStrong: Bool
}

/// Decides whether a respelling is a vocabulary fix rather than a rewrite.
public enum CorrectionGate {
    /// Passes "superbase" → "Supabase"; rejects "their" → "there" and "Kimi" → "Claude".
    public static func evaluate(heard: String, typed: String) -> VocabularyCorrection? {
        let heardWords = heard.split(separator: " ")
        let typedWords = typed.split(separator: " ")
        guard (1...3).contains(heardWords.count), (1...3).contains(typedWords.count),
              typed.count >= 3, heard.count >= 2,
              !VocabularyTuner.hasFunctionWordEdge(heard),
              !VocabularyTuner.hasFunctionWordEdge(typed) else { return nil }
        if typedWords.count == 1, isFunctionWord(String(typedWords[0])) { return nil }
        if heardWords.count == 1, isFunctionWord(String(heardWords[0])) { return nil }
        // Digits change meaning ("3" → "4"), not spelling.
        guard heard.filter(\.isNumber) == typed.filter(\.isNumber) else { return nil }

        if heard.lowercased() == typed.lowercased() {
            // Case only: a styled name ("GitHub"), not a hand-added sentence capital.
            guard heard != typed, hasStyledCase(typed) else { return nil }
            return VocabularyCorrection(heard: heard.lowercased(), typed: typed, isStrong: true)
        }
        let heardKey = PhoneticKey.key(heard)
        let typedKey = PhoneticKey.key(typed)
        let keyDistance = PhoneticKey.distance(heardKey, typedKey)
        // Dictionary word turned proper noun ("cloud code" → "Claude Code").
        let becameProperNoun = keyDistance == 0 && zip(heardWords, typedWords).contains {
            $0.first?.isLowercase == true && $1.first?.isUppercase == true
        }
        guard becameProperNoun || typedWords.contains(where: { isDistinctive(String($0)) }) else { return nil }

        let soundsAlike = keyDistance <= max(1, VocabularyTuner.tolerance(forKeyLength: typedKey.count))
        let spelledAlike = VocabularyTuner.spellingAgrees(heard: heard, anchor: typed)
        let letterDistance = EditDistance.between(Array(heard.lowercased()), Array(typed.lowercased()))
        let closeLetters = letterDistance <= max(2, typed.count / 3)
        guard soundsAlike || (spelledAlike && closeLetters) else { return nil }
        return VocabularyCorrection(
            heard: heard,
            typed: typed,
            isStrong: soundsAlike && spelledAlike && keyDistance <= VocabularyTuner.tolerance(forKeyLength: typedKey.count)
        )
    }

    /// Not ordinary English, or styled like a name ("GitHub", "iOS").
    static func isDistinctive(_ word: String) -> Bool {
        VocabularyTuner.isCandidateTerm(word) || hasStyledCase(word)
    }

    static func hasStyledCase(_ word: String) -> Bool {
        let letters = Array(word.filter(\.isLetter))
        guard letters.count >= 2 else { return false }
        if letters.dropFirst().contains(where: \.isUppercase) { return true }
        return false
    }

    private static func isFunctionWord(_ word: String) -> Bool {
        VocabularyTuner.hasFunctionWordEdge(word + " x")
    }
}

/// Finds the words a user retyped inside text Pressay just inserted.
public enum EditCorrectionDetector {
    /// Only 1–3 word substitutions wholly inside `inserted` count; appends, deletes and edits elsewhere are ignored.
    public static func corrections(baseline: String, inserted: Range<Int>, current: String) -> [VocabularyCorrection] {
        let old = WordDiff.words(in: baseline)
        let new = WordDiff.words(in: current)
        guard let hunks = WordDiff.hunks(old.map(\.text), new.map(\.text)) else { return [] }
        return hunks.compactMap { hunk in
            guard !hunk.old.isEmpty, !hunk.new.isEmpty, hunk.old.count <= 3, hunk.new.count <= 3 else { return nil }
            let oldWords = old[hunk.old]
            guard oldWords.allSatisfy({ inserted.contains($0.range.lowerBound) && $0.range.upperBound <= inserted.upperBound }) else {
                return nil
            }
            // One swallowed neighbor is fine; a 3 → 1 word rewrite isn't a respelling.
            guard abs(hunk.old.count - hunk.new.count) <= 1 else { return nil }
            let heard = oldWords.map(\.text).joined(separator: " ")
            let typed = new[hunk.new].map(\.text).joined(separator: " ")
            return CorrectionGate.evaluate(heard: heard, typed: typed)
        }
    }
}

/// A dictionary candidate awaiting the user's accept or dismiss.
public struct VocabularySuggestion: Codable, Equatable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// The user retyped it, but the match was too loose to apply alone.
        case edit
        /// AI cleanup kept respelling it the same way.
        case cleanup
        /// It recurs in dictations and isn't ordinary English.
        case recurring
    }

    /// Nil for a plain new word.
    public let heard: String?
    public let preferred: String
    public let origin: Origin
    public let count: Int
    public let example: String

    public init(heard: String?, preferred: String, origin: Origin, count: Int, example: String) {
        self.heard = heard
        self.preferred = preferred
        self.origin = origin
        self.count = count
        self.example = example
    }

    public var id: String { "\(heard?.lowercased() ?? "")→\(preferred.lowercased())" }
}

public enum VocabularyDiscovery {
    public struct Dictation: Sendable {
        public let raw: String
        public let polished: String
        public let date: Date
        public let usedLanguageModel: Bool

        public init(raw: String, polished: String, date: Date, usedLanguageModel: Bool) {
            self.raw = raw
            self.polished = polished
            self.date = date
            self.usedLanguageModel = usedLanguageModel
        }
    }

    /// `known`: lowercased dictionary terms and already-covered heard spellings.
    public static func suggestions(from dictations: [Dictation], known: Set<String>) -> [VocabularySuggestion] {
        let fixes = cleanupFixes(in: dictations, known: known)
        let covered = known.union(fixes.map { $0.preferred.lowercased() })
        return fixes + recurringTerms(in: dictations, known: covered)
    }

    /// Respellings the cleanup model made identically in 2+ dictations.
    static func cleanupFixes(in dictations: [Dictation], known: Set<String>) -> [VocabularySuggestion] {
        var counts: [String: (heard: String, typed: String, count: Int, example: String)] = [:]
        for dictation in dictations where dictation.usedLanguageModel {
            let raw = WordDiff.words(in: dictation.raw)
            let polished = WordDiff.words(in: dictation.polished)
            guard let hunks = WordDiff.hunks(
                raw.map(\.text), polished.map(\.text),
                equal: { $0.caseInsensitiveCompare($1) == .orderedSame }
            ) else { continue }
            var seenHere = Set<String>()
            for hunk in hunks where !hunk.old.isEmpty && !hunk.new.isEmpty
                && hunk.old.count <= 2 && hunk.new.count <= 2 {
                let heard = raw[hunk.old].map(\.text).joined(separator: " ")
                let typed = polished[hunk.new].map(\.text).joined(separator: " ")
                guard !known.contains(heard.lowercased()), !known.contains(typed.lowercased()),
                      let correction = CorrectionGate.evaluate(heard: heard, typed: typed),
                      correction.heard.lowercased() != correction.typed.lowercased() else { continue }
                let key = correction.heard.lowercased() + "→" + correction.typed
                guard seenHere.insert(key).inserted else { continue }
                let example = polished[hunk.new.lowerBound].range.lowerBound
                var entry = counts[key] ?? (correction.heard.lowercased(), correction.typed, 0, excerpt(dictation.polished, around: example))
                entry.count += 1
                counts[key] = entry
            }
        }
        return counts.values
            .filter { $0.count >= 2 }
            .sorted { ($0.count, $0.typed) > ($1.count, $1.typed) }
            .map { VocabularySuggestion(heard: $0.heard, preferred: $0.typed, origin: .cleanup, count: $0.count, example: $0.example) }
    }

    /// Non-English name-like words recurring in 3+ dictations over 2+ days.
    static func recurringTerms(in dictations: [Dictation], known: Set<String>) -> [VocabularySuggestion] {
        var tally: [String: (spellings: [String: Int], records: Int, days: Set<Date>, example: String)] = [:]
        let calendar = Calendar.current
        for dictation in dictations {
            let text = dictation.polished
            let words = WordDiff.words(in: text)
            var seenHere = Set<String>()
            for (index, word) in words.enumerated() {
                let fold = word.text.lowercased()
                guard word.text.count >= 3, !known.contains(fold),
                      VocabularyTuner.isCandidateTerm(word.text),
                      // Short acronyms ("ASR") come out spelled the same every time.
                      !(word.text.count <= 5 && word.text.allSatisfy(\.isUppercase)),
                      looksLikeName(word, index: index, in: text, words: words),
                      seenHere.insert(fold).inserted else { continue }
                var entry = tally[fold] ?? ([:], 0, [], excerpt(text, around: word.range.lowerBound))
                entry.spellings[word.text, default: 0] += 1
                entry.records += 1
                entry.days.insert(calendar.startOfDay(for: dictation.date))
                tally[fold] = entry
            }
        }
        return tally.values
            .filter { $0.records >= 3 && $0.days.count >= 2 }
            .compactMap { entry -> VocabularySuggestion? in
                guard let spelling = entry.spellings.max(by: { $0.value < $1.value })?.key else { return nil }
                return VocabularySuggestion(heard: nil, preferred: spelling, origin: .recurring, count: entry.records, example: entry.example)
            }
            .sorted { ($0.count, $0.preferred) > ($1.count, $1.preferred) }
    }

    static func looksLikeName(_ word: PositionedWord, index: Int, in text: String, words: [PositionedWord]) -> Bool {
        if CorrectionGate.hasStyledCase(word.text) || word.text.contains(where: \.isNumber) { return true }
        guard word.text.first?.isUppercase == true else { return false }
        // A capital at the start or after sentence punctuation is grammar.
        guard index > 0 else { return false }
        let characters = Array(text)
        var cursor = word.range.lowerBound - 1
        while cursor >= 0, characters[cursor].isWhitespace { cursor -= 1 }
        return cursor >= 0 && !".!?:\n".contains(characters[cursor])
    }

    static func excerpt(_ text: String, around offset: Int) -> String {
        let characters = Array(text)
        let lower = max(0, offset - 40)
        let upper = min(characters.count, offset + 50)
        var snippet = String(characters[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > 0 { snippet = "…" + snippet }
        if upper < characters.count { snippet += "…" }
        return snippet
    }
}
