import Foundation
import os

public enum VocabularyParser {
    /// Vocabulary changes rarely but normalize() runs on every dictation's
    /// insertion path; caching skips recompiling one regex per term per call.
    private static let regexCache = OSAllocatedUnfairLock<[String: NSRegularExpression]>(initialState: [:])

    private static func cachedRegex(for term: String) -> NSRegularExpression? {
        regexCache.withLock { cache in
            let pattern = wordBoundaryPattern(for: term)
            if let hit = cache[pattern] { return hit }
            let regex = try? NSRegularExpression(pattern: pattern)
            cache[pattern] = regex
            return regex
        }
    }
    public struct Entry: Equatable, Sendable {
        public let preferred: String
        public let aliases: [String]

        public init(preferred: String, aliases: [String] = []) {
            self.preferred = preferred
            self.aliases = aliases
        }
    }

    /// One entry per line. `preferred` or `preferred <= alias, another alias`.
    public static func parse(_ source: String) -> [Entry] {
        source.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let pieces = line.components(separatedBy: "<=")
            let preferred = pieces[0].trimmingCharacters(in: .whitespaces)
            guard !preferred.isEmpty else { return nil }
            let aliases = pieces.dropFirst().joined(separator: "<=")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Entry(preferred: preferred, aliases: aliases)
        }
    }

    /// The whole-word pattern normalize() replaces with; exposed so audits
    /// measure exactly what production matching will do.
    public static func wordBoundaryPattern(for term: String) -> String {
        "(?i)(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: term))(?![\\p{L}\\p{N}_])"
    }

    public static func normalize(_ text: String, entries: [Entry]) -> String {
        entries.reduce(text) { result, entry in
            let candidates = entry.aliases + [entry.preferred]
            return candidates.reduce(result) { partial, candidate in
                guard let regex = cachedRegex(for: candidate) else { return partial }
                let range = NSRange(partial.startIndex..., in: partial)
                return regex.stringByReplacingMatches(
                    in: partial,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.preferred)
                )
            }
        }
    }
}

public enum SpokenFormatting {
    private static let replacements: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("bullet point", "\n• "),
        ("bullet", "\n• "),
        ("open quote", "\"") ,
        ("close quote", "\""),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("colon", ":"),
        ("semicolon", ";"),
    ]

    private static let compiledReplacements: [(NSRegularExpression, String)] = replacements.compactMap {
        spoken, rendered in
        (try? NSRegularExpression(pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"))
            .map { ($0, NSRegularExpression.escapedTemplate(for: rendered)) }
    }

    public static func apply(to source: String) -> String {
        var text = source
        for (regex, template) in compiledReplacements {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
        text = text.replacingOccurrences(of: " \n", with: "\n")
        text = text.replacingOccurrences(of: "\n ", with: "\n")
        return text
    }
}

public enum DeterministicPromptCleaner {
    // Only unambiguous filler sounds. Phrases like "kind of", "sort of", and
    // "you know" carry meaning often enough ("some kind of plug-in system",
    // "do you know if…") that removing them changes what the speaker said.
    private static let fillerRegex = try? NSRegularExpression(
        pattern: #"(?i)(^|[\s,])(um+|uh+|erm+)(?=([\s,]|$))"#
    )

    private static let stutterRegex = try? NSRegularExpression(
        pattern: #"(?i)\b([\w'-]{2,})(\s+\1)+\b"#
    )

    /// Words that legitimately appear doubled in English ("so that that one
    /// also gets…", "he had had"); never collapse these.
    private static let legitimateDoubles: Set<String> = [
        "that", "had", "has", "is", "do", "no", "so", "can", "the", "a", "in",
        "it", "you", "we", "i", "very", "really",
    ]

    /// Bundle IDs where leading auto-capitalization corrupts input (shell
    /// commands are case-sensitive).
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    public static func clean(
        _ source: String,
        vocabulary: [VocabularyParser.Entry] = [],
        capitalizeFirstWord: Bool = true
    ) -> String {
        var text = SpokenFormatting.apply(to: source)
        text = removeAbandonedClause(beforeLastScratchThat: text)

        if let regex = fillerRegex {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }

        text = collapseStutters(in: text)

        text = VocabularyParser.normalize(text, entries: vocabulary)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if capitalizeFirstWord, let first = text.first, first.isLetter, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        }
        return text
    }

    /// Collapses immediate word stutters ("WhisperKit WhisperKit with…") that
    /// push-to-talk speech produces, while keeping grammatically legitimate
    /// doubles. Corpus-validated: fixes the stutters in history, touches
    /// nothing else.
    private static func collapseStutters(in source: String) -> String {
        guard let regex = stutterRegex else { return source }
        var text = source
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: text),
                  let firstWord = Range(match.range(at: 1), in: text) else { continue }
            let word = String(text[firstWord])
            guard !legitimateDoubles.contains(word.lowercased()) else { continue }
            text.replaceSubrange(whole, with: word)
        }
        return text
    }

    private static func removeAbandonedClause(beforeLastScratchThat source: String) -> String {
        let marker = "scratch that"
        guard let range = source.range(of: marker, options: [.caseInsensitive, .backwards]) else {
            return source
        }
        let prefix = source[..<range.lowerBound]
        let suffix = source[range.upperBound...]
        if let boundary = prefix.lastIndex(where: { ".!?;\n".contains($0) }) {
            return String(prefix[...boundary]) + String(suffix)
        }

        // Preserve a preceding coordinated clause when the abandoned and
        // replacement clauses start with the same action: “keep X and use
        // JSON, scratch that, use SQLite.” This avoids deleting “keep X.”
        let prefixText = String(prefix)
        if let connector = prefixText.range(
            of: #"(?i)\b(and|but|then)\b"#,
            options: [.regularExpression, .backwards]
        ) {
            let abandoned = prefixText[connector.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            let replacement = suffix
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if firstWord(in: abandoned) == firstWord(in: replacement) {
                return String(prefixText[..<connector.upperBound]) + " " + String(suffix)
            }
        }

        // If parsing is ambiguous, never discard an earlier constraint. The
        // literal correction phrase is safer than a meaning-changing edit.
        if ProtectedTokenValidator.protectedTokens(in: prefixText, vocabulary: []).isEmpty == false {
            return source
        }
        return String(suffix)
    }

    private static func firstWord<S: StringProtocol>(in text: S) -> String? {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map { String($0).lowercased() }
    }
}

public struct ProtectedTokenValidator: Sendable {
    public struct Validation: Equatable, Sendable {
        public let isValid: Bool
        public let missingTokens: [String]
        public let reason: String?
    }

    public init() {}

    public func validate(source: String, candidate: String, vocabulary: [String]) -> Validation {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Validation(isValid: false, missingTokens: [], reason: "empty output")
        }

        let protected = Self.protectedTokens(in: source, vocabulary: vocabulary)
        let candidateFolded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let missing = protected.filter { token in
            let foldedToken = Self.folded(token)
            if candidateFolded.contains(foldedToken) { return false }
            // A negation contraction survives as its expansion ("don't" -> "do not").
            return !Self.hasNegationEquivalent(of: foldedToken, in: candidateFolded)
        }
        guard missing.isEmpty else {
            return Validation(isValid: false, missingTokens: missing, reason: "protected tokens changed")
        }

        let sourceProtected = Set(protected.map { Self.folded($0) })
        let candidateProtected = Self.protectedTokens(in: trimmed, vocabulary: vocabulary)
        let added = candidateProtected.filter { token in
            let foldedToken = Self.folded(token)
            if sourceProtected.contains(foldedToken) { return false }
            // Expanding or contracting a negation only reshuffles words of the
            // same class ("not" in "do not" <-> "don't"), not an invention.
            guard let classWords = Self.negationClassWords(foldedToken) else { return true }
            return sourceProtected.isDisjoint(with: classWords)
        }
        guard added.isEmpty else {
            return Validation(isValid: false, missingTokens: added, reason: "protected tokens invented")
        }

        if Self.containsNegation(source), !Self.containsNegation(candidate) {
            return Validation(isValid: false, missingTokens: ["negation"], reason: "negation removed")
        }

        if Self.containsUncertainty(source), !Self.containsUncertainty(candidate) {
            return Validation(isValid: false, missingTokens: ["uncertainty"], reason: "uncertainty removed")
        }

        return Validation(isValid: true, missingTokens: [], reason: nil)
    }

    /// Single source of truth for what counts as a negation: token protection
    /// and the negation-removed check must never diverge.
    private static let negationWords = "no|not|never|without|don't|doesn't|didn't|can't|cannot|won't|shouldn't|mustn't"

    private static let protectedPatterns: [NSRegularExpression] = [
        #"https?://[^\s]+"#,
        #"\b\d+(?:[.,:]\d+)*(?:%|ms|s|GB|MB|KB|B)?\b"#,
        #"\b[A-Za-z]+(?:[_-][A-Za-z0-9]+)+\b"#,
        #"\b[a-z]+[A-Z][A-Za-z0-9]*\b"#,
        #"\b[A-Z]{2,}[A-Z0-9]*\b"#,
        // Single-letter model identifiers: K3, K2, M4, S3, ...
        #"\b[A-Z]\d+\b"#,
        "(?i)\\b(\(negationWords))\\b",
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let negationRegex = try? NSRegularExpression(pattern: "(?i)\\b(\(negationWords))\\b")
    private static let uncertaintyRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(maybe|perhaps|possibly|probably|might|may|could|i think|i guess|i suspect|not sure|uncertain)\b"#
    )

    /// Vocabulary terms occurring in the text; shared with the polisher so the
    /// prompt's vocabulary hint and the protected-token set cannot drift.
    public static func vocabularyTerms(in text: String, from vocabulary: [String]) -> [String] {
        vocabulary.filter { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    public static func protectedTokens(in text: String, vocabulary: [String]) -> [String] {
        var tokens = Set(vocabularyTerms(in: text, from: vocabulary))
        for regex in protectedPatterns {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let swiftRange = Range(match.range, in: text) {
                    tokens.insert(String(text[swiftRange]).trimmingCharacters(in: .punctuationCharacters))
                }
            }
        }
        return tokens.filter { !$0.isEmpty }.sorted()
    }

    private static func containsNegation(_ text: String) -> Bool {
        matches(negationRegex, in: text)
    }

    private static func containsUncertainty(_ text: String) -> Bool {
        matches(uncertaintyRegex, in: text)
    }

    private static func matches(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Contraction/expansion classes treated as the same negation when checking
    /// whether a protected token survived the rewrite.
    private static let negationEquivalents: [[String]] = [
        ["don't", "do not"],
        ["doesn't", "does not"],
        ["didn't", "did not"],
        ["can't", "cannot", "can not"],
        ["won't", "will not"],
        ["shouldn't", "should not"],
        ["mustn't", "must not"],
    ]

    /// Words of every negation class containing this token, if any. "not"
    /// belongs to several classes ("do not", "cannot", …), so the union is
    /// required — resolving only the first class rejects faithful rewrites
    /// like "cannot" -> "can not".
    private static func negationClassWords(_ foldedToken: String) -> Set<String>? {
        let classes = negationEquivalents
            .map { Set($0.flatMap { $0.split(separator: " ").map(String.init) }) }
            .filter { $0.contains(foldedToken) }
        guard !classes.isEmpty else { return nil }
        return classes.reduce(into: Set()) { $0.formUnion($1) }
    }

    /// Word-boundary match for another member of any of the token's negation
    /// classes, so "do nothing" does not satisfy "don't".
    private static func hasNegationEquivalent(of foldedToken: String, in candidateFolded: String) -> Bool {
        negationEquivalents
            .filter { $0.flatMap { $0.split(separator: " ").map(String.init) }.contains(foldedToken) }
            .contains { equivalents in
                equivalents.contains { equivalent in
                    equivalent != foldedToken && candidateFolded.range(
                        of: #"\b"# + NSRegularExpression.escapedPattern(for: equivalent) + #"\b"#,
                        options: .regularExpression
                    ) != nil
                }
            }
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum AudioTrimmer {
    /// - Parameter earconGuard: sample range holding the start cue, which now
    ///   plays into a live mic. Excluded from the onset search, and cut away
    ///   entirely unless the speaker began before it — that case means the
    ///   pre-roll caught a real word onset, which is worth more than a clean tone.
    public static func trim(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        frameMilliseconds: Int = 20,
        threshold: Float = 0.003,
        paddingMilliseconds: Int = 250,
        minimumOutputMilliseconds: Int = 1_200,
        earconGuard: Range<Int>? = nil
    ) throws -> [Float] {
        guard samples.count >= Int(Double(sampleRate) * DictationProcessingPolicy.minimumClipDuration) else {
            throw PressayError.recordingTooShort
        }
        let guardRange = earconGuard.map {
            max(0, $0.lowerBound)..<min(samples.count, max(0, $0.upperBound))
        }
        let frameSize = max(1, sampleRate * frameMilliseconds / 1_000)
        var firstSpeech: Int?
        var lastSpeech: Int?

        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(samples.count, start + frameSize)
            // The cue is louder than the speech threshold; scanning it would
            // anchor every clip's onset on the beep.
            if let guardRange, start < guardRange.upperBound, end > guardRange.lowerBound { continue }
            let frame = samples[start..<end]
            let rms = sqrt(frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, frame.count)))
            if rms >= threshold {
                firstSpeech = firstSpeech ?? start
                lastSpeech = end
            }
        }

        guard let firstSpeech, let lastSpeech else { throw PressayError.silence }
        let padding = sampleRate * paddingMilliseconds / 1_000
        var start = max(0, firstSpeech - padding)
        var end = min(samples.count, lastSpeech + padding)
        if let guardRange, firstSpeech >= guardRange.upperBound {
            start = max(start, guardRange.upperBound)
        }
        let minimumCount = sampleRate * minimumOutputMilliseconds / 1_000
        // Once the cue has been cut away, nothing below may reach back into it.
        let lowerLimit = guardRange.map { firstSpeech >= $0.upperBound ? $0.upperBound : 0 } ?? 0

        // Preserve available room around very short utterances before adding
        // synthetic silence. Whisper is substantially more reliable on one-word
        // clips when it receives at least about a second of acoustic context.
        if end - start < minimumCount {
            let missing = minimumCount - (end - start)
            let growBefore = min(start - lowerLimit, missing / 2)
            start -= growBefore
            end = min(samples.count, end + missing - growBefore)
            start = max(lowerLimit, start - max(0, minimumCount - (end - start)))
        }

        var output = Array(samples[start..<end])

        // Guarantee the encoder its full lead-in. Speech landing on frame 0 is
        // what a mic that opened mid-word produces, and Whisper-family models
        // drop or hallucinate that first token. The clip-length branch below
        // only ever covered utterances short enough to need topping up.
        let leadIn = firstSpeech - start
        if leadIn < padding {
            output = [Float](repeating: 0, count: padding - leadIn) + output
        }

        if output.count < minimumCount {
            let missing = minimumCount - output.count
            let before = missing / 2
            output = [Float](repeating: 0, count: before)
                + output
                + [Float](repeating: 0, count: missing - before)
        }
        return output
    }
}
