import Foundation

/// Spoken shortcut → stored text, e.g. "my calendar link" → a URL.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var trigger: String
    public var text: String

    public init(id: UUID = UUID(), trigger: String, text: String) {
        self.id = id
        self.trigger = trigger
        self.text = text
    }
}

public enum SnippetExpander {
    public static func exactMatch(_ text: String, snippets: [Snippet]) -> Snippet? {
        let spoken = normalized(text)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { !$0.text.isEmpty && normalized($0.trigger) == spoken }
    }

    /// Replaces each spoken trigger in one pass, ignoring case and the punctuation cleanup may have added
    /// around it, so text a snippet inserts is never expanded again.
    public static func expand(_ text: String, snippets: [Snippet]) -> String {
        if let whole = exactMatch(text, snippets: snippets) { return whole.text }
        // Longest first, so "my work email" wins over "my email".
        let usable = snippets
            .filter { !normalized($0.trigger).isEmpty && !$0.text.isEmpty }
            .sorted { normalized($0.trigger).count > normalized($1.trigger).count }
        guard !usable.isEmpty else { return text }
        let alternatives = usable.map { snippet in
            normalized(snippet.trigger).split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[^\\p{L}\\p{N}]+")
        }
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.map { "(\($0))" }.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1...usable.count).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += usable[group - 1].text
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
