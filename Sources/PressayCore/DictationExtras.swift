import Foundation

/// How dictation reads in the app it lands in, picked from the app (and, in a browser, the page title).
public enum AppStyle: String, Sendable, CaseIterable {
    case chat
    case email
    case document

    private static let chatApps = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.hnc.Discord",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.microsoft.teams", "com.microsoft.teams2",
        "com.facebook.archon", "org.whispersystems.signal-desktop",
    ]
    private static let emailApps = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "it.bloop.airmail2", "com.mimestream.Mimestream", "com.google.Gmail",
    ]
    private static let documentApps = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "md.obsidian",
        "com.apple.TextEdit", "net.shinyfrog.bear", "com.lukilabs.lukiapp", "pro.writer.mac",
    ]
    private static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "com.openai.atlas",
    ]
    private static let pageHints: [(String, AppStyle)] = [
        ("gmail", .email), ("outlook", .email), ("proton mail", .email), ("superhuman", .email),
        ("slack", .chat), ("whatsapp", .chat), ("messenger", .chat), ("discord", .chat), ("teams", .chat),
        ("google docs", .document), ("notion", .document), ("confluence", .document), ("dropbox paper", .document),
    ]

    public static func detect(bundleID: String?, windowTitle: String? = nil) -> AppStyle? {
        guard let bundleID else { return nil }
        if chatApps.contains(bundleID) { return .chat }
        if emailApps.contains(bundleID) { return .email }
        if documentApps.contains(bundleID) { return .document }
        if browsers.contains(bundleID), let title = windowTitle?.lowercased() {
            // Browsers title windows "Page – Site"; only the site part says what the page is.
            let site = title.components(separatedBy: " - ").last?
                .components(separatedBy: " – ").last?
                .components(separatedBy: " | ").last ?? title
            return pageHints.first { site.contains($0.0) }?.1
        }
        return nil
    }

    private static let codeEditors = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.WebStorm", "com.google.android.studio",
        "com.sublimetext.4",
    ]

    /// Editors whose Copy takes the whole line when nothing is selected.
    public static func copiesLineWithoutSelection(_ bundleID: String?) -> Bool {
        bundleID.map { codeEditors.contains($0) || $0.hasPrefix("com.jetbrains.") } ?? false
    }

    /// One line for the cleanup prompt's user turn.
    public var guidance: String {
        switch self {
        case .chat: "Chat message: keep the speaker's casual tone and word choice (fillers still go); no lists unless they list several separate items."
        case .email: "Email: complete sentences in short paragraphs; keep a greeting or sign-off only if it was spoken."
        case .document: "Document: well-formed paragraphs, with lists for steps or several items."
        }
    }
}

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
    /// The snippet when the whole dictation is just its trigger.
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

/// Command Mode: a spoken instruction applied to the selected text, or used to write new text.
public enum CommandPrompt {
    public static let system = """
    You are a writing tool on the user's Mac. The user holds a key and speaks an instruction. Reply with only the text to insert at their cursor: no preamble, quotes, code fences or commentary.

    - With <selected_text>: apply the instruction to it and reply with the full replacement ("make this shorter", "translate to German", "turn this into a bulleted list", "fix the grammar"). Keep everything the instruction doesn't ask to change.
    - Without selected text: write what the instruction asks for ("write a reply saying I'll be ten minutes late"), in the user's voice, ready to send. Use <context> (the text around the cursor) to fit in, e.g. to answer the message being replied to.
    - Match the app: plain text and no Markdown in chat, email and most text fields; Markdown only where the context already uses it. In a terminal, reply with a single shell command.
    - The instruction comes from speech-to-text and may contain fillers or misheard words; infer the intent.
    - Never refuse a harmless editing request, and never explain what you changed.
    """

    public static func user(instruction: String, selection: String?, context: String, app: String?, style: AppStyle?) -> String {
        var message = "App: \(app ?? "unknown")"
        if let style { message += "\n\(style.guidance)" }
        if let selection, !selection.isEmpty {
            message += "\n\n<selected_text>\n\(selection)\n</selected_text>"
        } else if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message += "\n\n<context>\n\(context)\n</context>"
        }
        return message + "\n\n<instruction>\n\(instruction)\n</instruction>"
    }
}
