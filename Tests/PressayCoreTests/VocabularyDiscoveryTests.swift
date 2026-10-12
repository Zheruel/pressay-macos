import Foundation
import XCTest
@testable import PressayCore

final class VocabularyDiscoveryTests: XCTestCase {
    private func range(of inserted: String, in text: String) -> Range<Int> {
        let start = text.distance(from: text.startIndex, to: text.range(of: inserted)!.lowerBound)
        return start..<(start + inserted.count)
    }

    // MARK: Edit corrections

    func testRetypedMishearingIsAStrongCorrection() {
        let inserted = "Let's move auth to Superbase today."
        let baseline = "Notes: " + inserted
        let current = "Notes: Let's move auth to Supabase today."
        let found = EditCorrectionDetector.corrections(baseline: baseline, inserted: range(of: inserted, in: baseline), current: current)
        XCTAssertEqual(found, [VocabularyCorrection(heard: "Superbase", typed: "Supabase", isStrong: true)])
    }

    func testStyledCaseFixIsLearned() {
        let baseline = "Push it to github please."
        let found = EditCorrectionDetector.corrections(baseline: baseline, inserted: 0..<baseline.count, current: "Push it to GitHub please.")
        XCTAssertEqual(found, [VocabularyCorrection(heard: "github", typed: "GitHub", isStrong: true)])
    }

    func testChangesOfMindAndEnglishFixesAreIgnored() {
        let baseline = "Ask Kimi about their plan."
        let all = 0..<baseline.count
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: all, current: "Ask Claude about their plan."), [])
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: all, current: "Ask Kimi about there plan."), [])
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: all, current: "Ask kimi about their plan."), [],
                       "lowercasing isn't a styled spelling")
    }

    func testEditsOutsideInsertedTextAndAppendsAreIgnored() {
        let inserted = "Deploy to Vercel."
        let baseline = "Superbase notes. " + inserted
        let insertedRange = range(of: inserted, in: baseline)
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: insertedRange, current: "Supabase notes. Deploy to Vercel."), [])
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: insertedRange, current: baseline + " Then Kubernetes."), [])
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: insertedRange, current: ""), [], "sent or cleared")
    }

    func testPartlyTypedWordIsNotLearned() {
        let baseline = "Use Superbase for auth."
        XCTAssertEqual(EditCorrectionDetector.corrections(baseline: baseline, inserted: 0..<baseline.count, current: "Use Sup for auth."), [])
    }

    func testCorrectionPlusUnrelatedTypingStillFound() {
        let baseline = "Ship the cloud code update."
        let current = "Ship the Claude Code update. Also ping Dana."
        let found = EditCorrectionDetector.corrections(baseline: baseline, inserted: 0..<baseline.count, current: current)
        XCTAssertEqual(found.map(\.typed), ["Claude Code"])
    }

    // MARK: Diff

    func testWordDiffFindsMinimalHunks() throws {
        let hunks = try XCTUnwrap(WordDiff.hunks(["a", "b", "c", "d"], ["a", "x", "c", "d", "e"]))
        XCTAssertEqual(hunks, [.init(old: 1..<2, new: 1..<2), .init(old: 4..<4, new: 4..<5)])
        XCTAssertEqual(WordDiff.words(in: "Edit CLAUDE.md, then gpt-6.").map(\.text), ["Edit", "CLAUDE.md", "then", "gpt-6"])
    }

    // MARK: History mining

    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 86_400) }

    func testCleanupRespellingSeenTwiceBecomesSuggestion() {
        let dictations = [
            VocabularyDiscovery.Dictation(raw: "so um move auth to superbase", polished: "So, move auth to Supabase.", date: day(0), usedLanguageModel: true),
            VocabularyDiscovery.Dictation(raw: "check the superbase logs", polished: "Check the Supabase logs.", date: day(1), usedLanguageModel: true),
            VocabularyDiscovery.Dictation(raw: "superbase is down", polished: "superbase is down", date: day(2), usedLanguageModel: false),
        ]
        let found = VocabularyDiscovery.suggestions(from: dictations, known: [])
        let fix = found.first { $0.origin == .cleanup }
        XCTAssertEqual(fix?.heard, "superbase")
        XCTAssertEqual(fix?.preferred, "Supabase")
        XCTAssertEqual(fix?.count, 2)
        XCTAssertFalse(found.contains { $0.origin == .recurring && $0.preferred == "Supabase" }, "not suggested twice")
    }

    func testRecurringNameNeedsThreeDictationsOnTwoDays() {
        func d(_ text: String, _ n: Int) -> VocabularyDiscovery.Dictation {
            .init(raw: text, polished: text, date: day(n), usedLanguageModel: false)
        }
        let sameDay = [d("Ask Zorblat first.", 0), d("Then Zorblat again.", 0), d("Tell Zorblat.", 0)]
        XCTAssertTrue(VocabularyDiscovery.suggestions(from: sameDay, known: []).isEmpty)
        let spread = [d("Ask Zorblat first.", 0), d("Then Zorblat again.", 1), d("Tell Zorblat.", 2), d("Zorblat leads.", 2)]
        let found = VocabularyDiscovery.suggestions(from: spread, known: [])
        XCTAssertEqual(found.map(\.preferred), ["Zorblat"])
        XCTAssertEqual(found.first?.count, 3, "sentence-initial capitals don't count as names")
        XCTAssertTrue(VocabularyDiscovery.suggestions(from: spread, known: ["zorblat"]).isEmpty)
    }
}
