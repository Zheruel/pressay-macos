import Foundation
@testable import PressayCore
import Testing

struct SnippetTests {
    private let snippets = [
        Snippet(trigger: "my calendar link", text: "https://cal.com/tin"),
        Snippet(trigger: "my email", text: "tin@example.com"),
        Snippet(trigger: "my work email", text: "tin@work.com"),
    ]

    @Test func wholeDictationBecomesTheSnippet() {
        #expect(SnippetExpander.exactMatch("My calendar link.", snippets: snippets)?.text == "https://cal.com/tin")
        #expect(SnippetExpander.exactMatch("send my calendar link", snippets: snippets) == nil)
    }

    @Test func expandsInsideTextIgnoringCaseAndPunctuation() {
        #expect(SnippetExpander.expand("Book a slot here: My calendar link.", snippets: snippets)
            == "Book a slot here: https://cal.com/tin.")
        #expect(SnippetExpander.expand("Reach me at my work email, thanks.", snippets: snippets)
            == "Reach me at tin@work.com, thanks.")
        // Whole words only.
        #expect(SnippetExpander.expand("Check my emails", snippets: snippets) == "Check my emails")
    }

    @Test func snippetTextIsLiteral() {
        let dollar = [Snippet(trigger: "price line", text: "Costs $1 \\o/")]
        #expect(SnippetExpander.expand("The price line today", snippets: dollar) == "The Costs $1 \\o/ today")
    }

    @Test func insertedTextIsNotExpandedAgain() {
        let chained = [
            Snippet(trigger: "my signature", text: "Tin, my email"),
            Snippet(trigger: "my email", text: "tin@example.com"),
            Snippet(trigger: "John's email", text: "john@example.com"),
        ]
        #expect(SnippetExpander.expand("Thanks, my signature", snippets: chained) == "Thanks, Tin, my email")
        #expect(SnippetExpander.expand("Ask John’s email first", snippets: chained) == "Ask john@example.com first")
    }
}

struct AppStyleTests {
    @Test func detectsAppsAndBrowserPages() {
        #expect(AppStyle.detect(bundleID: "com.tinyspeck.slackmacgap") == .chat)
        #expect(AppStyle.detect(bundleID: "com.apple.mail") == .email)
        #expect(AppStyle.detect(bundleID: "com.google.Chrome", windowTitle: "Inbox (3) - tin@x.com - Gmail") == .email)
        #expect(AppStyle.detect(bundleID: "com.google.Chrome", windowTitle: "Pull requests") == nil)
        #expect(AppStyle.detect(bundleID: "com.microsoft.VSCode") == nil)
        #expect(AppStyle.detect(bundleID: "com.google.Chrome", windowTitle: "Q4 Outlook - Google Docs") == .document)
    }

    @Test func cleanupPromptCarriesTheStyle() {
        let user = ClaudeCleanupPrompt.user(transcript: "hi", targetBundleID: "com.apple.mail", style: .email)
        #expect(user.hasPrefix("App: com.apple.mail\nEmail:"))
        #expect(ClaudeCleanupPrompt.user(transcript: "hi", targetBundleID: nil) == "App: unknown\n\n<transcript>\nhi\n</transcript>")
    }
}

struct CommandPromptTests {
    @Test func selectionWinsOverContext() {
        let user = CommandPrompt.user(instruction: "shorter", selection: "Long text", context: "around", app: "com.apple.Notes", style: nil)
        #expect(user.contains("<selected_text>\nLong text"))
        #expect(!user.contains("<context>"))
        #expect(user.hasSuffix("<instruction>\nshorter\n</instruction>"))
    }

    @Test func contextWithoutSelection() {
        let user = CommandPrompt.user(instruction: "reply yes", selection: nil, context: "Can we meet?", app: nil, style: .chat)
        #expect(user.contains("<context>\nCan we meet?"))
        #expect(user.contains("Chat message"))
    }
}

struct ActionItemTests {
    @Test func parsesOwnersAndState() {
        let body = """
        Summary.

        ## Action items
        - [ ] Send the deck to Dana (me)
        - [x] Check seed data (Leo)
        - [ ] Decide on pricing (owner unclear)
        - Not a task (me)
        """
        let items = ActionItem.parse(body)
        #expect(items.map(\.text) == ["Send the deck to Dana", "Check seed data", "Decide on pricing"])
        #expect(items.map(\.line) == [3, 4, 5])
        #expect(items[0].isMine && !items[0].done)
        #expect(items[1].owner == "Leo" && items[1].done)
        #expect(items[2].owner == nil)
        #expect(ActionItem.otherOwners(in: body) == ["Leo"])
        #expect(ActionItem.parse("- [ ] Review plan (draft)").first?.text == "Review plan (draft)")
        #expect(ActionItem.parse("- [ ] Send the deck (Friday)").first?.owner == nil)
    }

    @Test func togglesTheSameItemEvenAfterEdits() {
        let body = "- [ ] Ship it\n- [x] Fix [ ] markup"
        let items = ActionItem.parse(body)
        #expect(ActionItem.toggling(items[1], in: body) == "- [ ] Ship it\n- [ ] Fix [ ] markup")
        #expect(ActionItem.toggling(items[0], in: "Intro\n" + body) == "Intro\n- [x] Ship it\n- [x] Fix [ ] markup")
    }

    @Test func writeUpKeepsTicks() {
        let old = "- [x] Send the deck (me)\n- [ ] Call Dana"
        let new = "## Action items\n- [ ] Send the deck (me)\n- [ ] Call Dana (Leo)"
        #expect(ActionItem.carryingTicks(from: old, into: new) == "## Action items\n- [x] Send the deck (me)\n- [ ] Call Dana (Leo)")
    }

    @Test func participantsReachTheWriteUp() {
        let lines = [TranscriptLine(speaker: .others, start: 0, text: "hi")]
        #expect(MeetingPrompt.user(lines: lines, participants: ["Priya"]).hasPrefix("The only other person on the call was Priya"))
        #expect(MeetingPrompt.user(lines: lines).hasPrefix("<transcript>"))
    }
}
