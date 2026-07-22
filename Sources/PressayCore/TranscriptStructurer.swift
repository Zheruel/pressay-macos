import Foundation

/// Deterministic structuring for dictated prose: terminal punctuation,
/// sentence capitalization, spoken enumerations as bullet lists, and
/// paragraph breaks. Runs after `DeterministicPromptCleaner.clean` and only
/// rearranges presentation — it never reorders, adds, or removes words, so
/// `ProtectedTokenValidator` always passes on its output.
public enum TranscriptStructurer {
    public struct Options: Sendable {
        /// Inputs shorter than this pass through untouched — a chat reply or
        /// search query has nothing to structure.
        public var minimumWordCount: Int
        /// Insert sentence breaks before strong spoken connectors when the
        /// text has almost no terminal punctuation (Parakeet-style output).
        public var repairMissingPunctuation: Bool
        public var maxSentencesPerParagraph: Int

        public init(
            minimumWordCount: Int = 15,
            repairMissingPunctuation: Bool = true,
            maxSentencesPerParagraph: Int = 4
        ) {
            self.minimumWordCount = minimumWordCount
            self.repairMissingPunctuation = repairMissingPunctuation
            self.maxSentencesPerParagraph = maxSentencesPerParagraph
        }
    }

    public static func structure(_ text: String, options: Options = Options()) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount(of: trimmed) >= options.minimumWordCount else { return text }

        // Blocks separated by blank lines came from the speaker ("new
        // paragraph") or a previous structuring pass; never merge across
        // them. Blocks containing their own newlines or bullets carry
        // user-spoken structure and pass through untouched.
        let blocks = trimmed.components(separatedBy: blankLineSeparator)
        let structured = blocks.map { block -> String in
            let blockTrimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !blockTrimmed.contains("\n"), !startsWithBullet(blockTrimmed) else {
                return blockTrimmed
            }
            return structureBlock(blockTrimmed, options: options)
        }
        return structured.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let blankLineSeparator = "\n\n"

    // MARK: - Per-block pipeline

    private static func structureBlock(_ block: String, options: Options) -> String {
        var text = block
        if options.repairMissingPunctuation {
            text = repairPunctuation(in: text)
        }
        if let last = text.last, last.isLetter || last.isNumber {
            text += "."
        }

        var sentences = split(intoSentences: text)
        sentences = sentences.map(capitalizeSentenceStart)

        let segments = detectLists(in: sentences)
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty {
                paragraphs.append(current.joined(separator: " "))
                current = []
            }
        }
        for segment in segments {
            switch segment {
            case .list(let items):
                flush()
                paragraphs.append(items.map { "- \($0)" }.joined(separator: "\n"))
            case .sentence(let sentence):
                if startsNewParagraph(sentence), !current.isEmpty {
                    flush()
                } else if current.count >= options.maxSentencesPerParagraph {
                    flush()
                }
                current.append(sentence)
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func startsWithBullet(_ text: String) -> Bool {
        text.hasPrefix("- ") || text.hasPrefix("• ") || text.hasPrefix("* ")
    }

    // MARK: - Punctuation repair

    /// Connectors that reliably open a fresh spoken sentence. Deliberately
    /// short — "also" and "then" appear mid-sentence far too often. A comma
    /// before the connector never matches: the speaker already punctuated.
    private static let breakConnectors = try? NSRegularExpression(
        pattern: #"(?i)([a-z0-9])[ \t]+(and then|okay so|so then|anyway|by the way)\b"#
    )

    /// Words a run must stretch past the previous punctuation before a
    /// connector earns an inserted break. Measured locally per connector so
    /// the decision is identical whether the text is seen whole or as an
    /// already-split paragraph — that keeps structuring idempotent.
    private static let minimumRunWords = 15

    /// Breaks up punctuationless run-ons (Parakeet-style output) at strong
    /// connectors; punctuated Whisper output is left alone.
    private static func repairPunctuation(in text: String) -> String {
        guard let regex = breakConnectors else { return text }
        var result = text
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let lead = Range(match.range(at: 1), in: result),
                  let connector = Range(match.range(at: 2), in: result) else { continue }
            let prefix = result[..<connector.lowerBound]
            let lastMark = prefix.lastIndex { ".!?,;:".contains($0) }
            let runStart = lastMark.map { prefix.index(after: $0) } ?? prefix.startIndex
            let runWords = prefix[runStart...].split(whereSeparator: \.isWhitespace).count
            guard runWords >= minimumRunWords else { continue }
            result.replaceSubrange(
                whole, with: result[lead] + ". " + result[connector]
            )
        }
        return result
    }

    // MARK: - Sentence segmentation

    /// Tokens whose trailing period is not a sentence end.
    private static let abbreviations: Set<String> = [
        "e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no",
    ]

    static func split(intoSentences text: String) -> [String] {
        var sentences: [String] = []
        var start = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard ".!?".contains(character) else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            while end < text.endIndex, ".!?\"')".contains(text[end]) {
                end = text.index(after: end)
            }
            let isBoundary = end == text.endIndex || text[end].isWhitespace
            if isBoundary, character != "." || !endsWithAbbreviation(text[start..<end]) {
                let sentence = text[start..<end].trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { sentences.append(sentence) }
                while end < text.endIndex, text[end].isWhitespace {
                    end = text.index(after: end)
                }
                start = end
                index = end
            } else {
                index = end
            }
        }
        if start < text.endIndex {
            let remainder = text[start...].trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty { sentences.append(remainder) }
        }
        return sentences
    }

    private static func endsWithAbbreviation(_ sentence: Substring) -> Bool {
        // Trailing token before the final period, e.g. "e.g", "etc", "K3", "v2".
        guard let match = sentence.range(
            of: #"[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)*\.$"#,
            options: .regularExpression
        ) else { return false }
        let token = sentence[match].dropLast().lowercased()
        if abbreviations.contains(token) { return true }
        // Single letters ("J. Smith") and dotted identifiers ("node.js",
        // "package.json") never end a sentence on their own account.
        return token.count == 1 || token.contains(".")
    }

    private static func capitalizeSentenceStart(_ sentence: String) -> String {
        guard let firstWord = sentence.split(whereSeparator: \.isWhitespace).first,
              firstWord.allSatisfy({ $0.isLowercase || !$0.isLetter }),
              let first = sentence.first, first.isLetter, first.isLowercase else {
            return sentence
        }
        var result = sentence
        result.replaceSubrange(result.startIndex...result.startIndex, with: String(first).uppercased())
        return result
    }

    // MARK: - List detection

    private enum Segment {
        case sentence(String)
        case list([String])
    }

    /// Explicit openers a spoken enumeration starts with; a run of bare
    /// "then/next" sentences alone never becomes a list.
    private static let listStarters = ["first", "firstly", "number one", "one,", "step one"]
    private static let listContinuers = [
        "second", "secondly", "third", "thirdly", "fourth", "fourthly", "fifth",
        "next", "then", "finally", "lastly", "last", "number two", "number three",
        "number four", "number five", "step two", "step three", "two,", "three,",
        "four,", "five,",
    ]

    private static func detectLists(in sentences: [String]) -> [Segment] {
        var segments: [Segment] = []
        var index = 0
        while index < sentences.count {
            guard leadingMarker(in: sentences[index], among: listStarters) != nil else {
                segments.append(.sentence(sentences[index]))
                index += 1
                continue
            }
            var run = [sentences[index]]
            var lookahead = index + 1
            while lookahead < sentences.count,
                  leadingMarker(in: sentences[lookahead], among: listContinuers) != nil {
                run.append(sentences[lookahead])
                lookahead += 1
            }
            if run.count >= 2 {
                let items = run.map { sentence -> String in
                    let marker = leadingMarker(in: sentence, among: listStarters + listContinuers)!
                    return capitalizeSentenceStart(stripMarker(marker, from: sentence))
                }
                segments.append(.list(items))
                index = lookahead
            } else {
                segments.append(.sentence(sentences[index]))
                index += 1
            }
        }
        return segments
    }

    private static func leadingMarker(in sentence: String, among markers: [String]) -> String? {
        let fold = sentence.lowercased()
        return markers.first { marker in
            guard fold.hasPrefix(marker) else { return false }
            if marker.hasSuffix(",") { return true }
            // Word boundary: "then" must not match "then-branch" or "theory".
            let after = fold.index(fold.startIndex, offsetBy: marker.count)
            return after == fold.endIndex || fold[after] == "," || fold[after] == ":"
                || fold[after].isWhitespace
        }
    }

    private static func stripMarker(_ marker: String, from sentence: String) -> String {
        var rest = String(sentence.dropFirst(marker.count))
        while let first = rest.first, first == "," || first == ":" || first.isWhitespace {
            rest.removeFirst()
        }
        return rest.isEmpty ? sentence : rest
    }

    // MARK: - Paragraphing

    private static let paragraphMarkers = [
        "also", "anyway", "by the way", "separately", "on another note",
        "one more thing", "moving on", "okay so", "now",
    ]

    private static func startsNewParagraph(_ sentence: String) -> Bool {
        leadingMarker(in: sentence, among: paragraphMarkers) != nil
    }
}
