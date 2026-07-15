import Foundation

public enum VocabularyParser {
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

    public static func normalize(_ text: String, entries: [Entry]) -> String {
        entries.reduce(text) { result, entry in
            let candidates = entry.aliases + [entry.preferred]
            return candidates.reduce(result) { partial, candidate in
                guard let regex = try? NSRegularExpression(
                    pattern: "(?i)(?<![\\p{L}\\p{N}_])\(NSRegularExpression.escapedPattern(for: candidate))(?![\\p{L}\\p{N}_])"
                ) else { return partial }
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

    public static func apply(to source: String) -> String {
        var text = source
        for (spoken, rendered) in replacements {
            guard let regex = try? NSRegularExpression(
                pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: spoken))\\b"
            ) else { continue }
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: rendered)
            )
        }
        text = text.replacingOccurrences(of: " \n", with: "\n")
        text = text.replacingOccurrences(of: "\n ", with: "\n")
        return text
    }
}

public enum DeterministicPromptCleaner {
    private static let fillerPattern = #"(?i)(^|[\s,])(um+|uh+|erm+|you know|kind of|sort of)(?=([\s,]|$))"#

    public static func clean(_ source: String, vocabulary: [VocabularyParser.Entry] = []) -> String {
        var text = SpokenFormatting.apply(to: source)
        text = removeAbandonedClause(beforeLastScratchThat: text)

        if let regex = try? NSRegularExpression(pattern: fillerPattern) {
            text = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "$1"
            )
        }

        text = VocabularyParser.normalize(text, entries: vocabulary)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let first = text.first, first.isLetter, first.isLowercase {
            text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
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

public enum PromptPolishGate {
    private static let usefulRewriteSignal = #"(?i)\b(um+|uh+|erm+|you know|kind of|sort of|scratch that|new paragraph|new line|bullet point|bullet|open quote|close quote|please|can you|could you|would you|take a look|see if you can|make sure)\b"#

    /// The local language model is valuable for disfluent or indirect speech,
    /// but unnecessary rewriting makes already-clean prompts less faithful.
    public static func shouldUseLanguageModel(for rawTranscript: String) -> Bool {
        rawTranscript.range(of: usefulRewriteSignal, options: .regularExpression) != nil
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
            !candidateFolded.contains(token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
        guard missing.isEmpty else {
            return Validation(isValid: false, missingTokens: missing, reason: "protected tokens changed")
        }

        let sourceProtected = Set(protected.map { Self.folded($0) })
        let candidateProtected = Self.protectedTokens(in: trimmed, vocabulary: vocabulary)
        let added = candidateProtected.filter { !sourceProtected.contains(Self.folded($0)) }
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

    public static func protectedTokens(in text: String, vocabulary: [String]) -> [String] {
        var tokens = Set(vocabulary.filter { term in
            text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        })
        let patterns = [
            #"https?://[^\s]+"#,
            #"\b\d+(?:[.,:]\d+)*(?:%|ms|s|GB|MB|KB|B)?\b"#,
            #"\b[A-Za-z]+(?:[_-][A-Za-z0-9]+)+\b"#,
            #"\b[a-z]+[A-Z][A-Za-z0-9]*\b"#,
            #"\b[A-Z]{2,}[A-Z0-9]*\b"#,
            #"(?i)\b(no|not|never|without|don't|doesn't|didn't|can't|cannot|won't|shouldn't|mustn't)\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
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
        let pattern = #"(?i)\b(no|not|never|without|don't|doesn't|didn't|can't|cannot|won't|shouldn't|mustn't)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsUncertainty(_ text: String) -> Bool {
        let pattern = #"(?i)\b(maybe|perhaps|possibly|probably|might|may|could|i think|i guess|i suspect|not sure|uncertain)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public enum AudioTrimmer {
    public static func trim(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        frameMilliseconds: Int = 20,
        threshold: Float = 0.003,
        paddingMilliseconds: Int = 250,
        minimumOutputMilliseconds: Int = 1_200
    ) throws -> [Float] {
        guard samples.count >= sampleRate / 4 else { throw LocalFlowError.recordingTooShort }
        let frameSize = max(1, sampleRate * frameMilliseconds / 1_000)
        var firstSpeech: Int?
        var lastSpeech: Int?

        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(samples.count, start + frameSize)
            let frame = samples[start..<end]
            let rms = sqrt(frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(max(1, frame.count)))
            if rms >= threshold {
                firstSpeech = firstSpeech ?? start
                lastSpeech = end
            }
        }

        guard let firstSpeech, let lastSpeech else { throw LocalFlowError.silence }
        let padding = sampleRate * paddingMilliseconds / 1_000
        var start = max(0, firstSpeech - padding)
        var end = min(samples.count, lastSpeech + padding)
        let minimumCount = sampleRate * minimumOutputMilliseconds / 1_000

        // Preserve available room around very short utterances before adding
        // synthetic silence. Whisper is substantially more reliable on one-word
        // clips when it receives at least about a second of acoustic context.
        if end - start < minimumCount {
            let missing = minimumCount - (end - start)
            let growBefore = min(start, missing / 2)
            start -= growBefore
            end = min(samples.count, end + missing - growBefore)
            start = max(0, start - max(0, minimumCount - (end - start)))
        }

        var output = Array(samples[start..<end])
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
