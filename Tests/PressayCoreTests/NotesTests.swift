import XCTest
@testable import PressayCore

final class NotePromptTests: XCTestCase {
    func testOrganizedPromptMatchesBenchmarkedText() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/notes/prompt-v4.txt").path
        let prompt = NotePrompt.system(style: .organized, vocabulary: [.init(preferred: "Telnyx")])
        let benchmarked = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(prompt, benchmarked.trimmingCharacters(in: .newlines).replacingOccurrences(of: "{vocab}", with: "Telnyx"))
    }

    func testParseSplitsTitleAndBody() throws {
        let note = try XCTUnwrap(NotePrompt.parse("# Dutch dialect detection.\n\nWe need a model.\n\n## To do\n- [ ] Pick one"))
        XCTAssertEqual(note.title, "Dutch dialect detection")
        XCTAssertEqual(note.body, "We need a model.\n\n## To do\n- [ ] Pick one")
        XCTAssertEqual(NotePrompt.fallbackTitle(for: "Call the bank about the card tomorrow morning please"), "Call the bank about the card…")
    }
}

final class MeetingPromptTests: XCTestCase {
    func testTranscriptFormat() {
        let user = MeetingPrompt.user(lines: [
            TranscriptLine(speaker: .me, start: 3, text: "Can you hear me?"),
            TranscriptLine(speaker: .others, start: 3_725, text: "Yes."),
        ])
        XCTAssertEqual(user, "<transcript>\n[0:03] Me: Can you hear me?\n[1:02:05] Others: Yes.\n</transcript>")
        XCTAssertFalse(MeetingPrompt.system(vocabulary: []).contains("{vocab}"))
    }

    func testPromptMatchesBenchmarkedFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/notes/meetings/meeting-prompt.txt")
        let file = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        XCTAssertEqual(MeetingPrompt.prompt, file)
    }

    func testSummaryOnFirstLineKeepsWholeReply() throws {
        let reply = "We reviewed the Q3 budget and agreed to cut the events line by twenty percent while keeping hiring flat.\n\n## Decisions\n- Cut events"
        let parsed = try XCTUnwrap(NotePrompt.parse(reply))
        XCTAssertTrue(parsed.body.hasPrefix("We reviewed"))
        XCTAssertTrue(parsed.title.hasSuffix("…"))
    }
}
