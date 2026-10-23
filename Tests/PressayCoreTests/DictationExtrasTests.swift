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
