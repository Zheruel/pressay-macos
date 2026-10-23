#if DEBUG
    import AppKit
    import Foundation
    import PressayCore

    /// Isolated, synthetic data for repeatable native screenshot comparisons.
    /// Release builds contain neither this mode nor its fixtures.
    @MainActor
    enum DesignReview {
        static var enabled: Bool { ProcessInfo.processInfo.environment["PRESSAY_DESIGN_REVIEW"] == "1" }
        static var appearance: NSAppearance? {
            ProcessInfo.processInfo.environment["PRESSAY_REVIEW_APPEARANCE"].flatMap {
                NSAppearance(named: $0 == "light" ? .aqua : .darkAqua)
            }
        }
        static let defaults: UserDefaults = {
            guard enabled else { return .standard }
            let name = "dev.pressay.design-review.\(ProcessInfo.processInfo.processIdentifier)"
            let store = UserDefaults(suiteName: name)!
            store.removePersistentDomain(forName: name)
            store.set(true, forKey: "onboardingComplete")
            store.set(false, forKey: "notesUseAI")
            store.set(
                "# Design & tools\nFigma\nNotion\n# Your words\nPressay\nTin\n# Development\nSupabase\nTypeScript",
                forKey: "vocabulary")
            let snippets = [
                Snippet(trigger: "my calendar link", text: "https://cal.com/your-name"),
                Snippet(trigger: "my address", text: "42 Market Street\nSan Francisco, CA"),
                Snippet(trigger: "email sign off", text: "Best,\nTin"),
            ]
            store.set(try? JSONEncoder().encode(snippets), forKey: "snippets")
            if ProcessInfo.processInfo.environment["PRESSAY_REVIEW_EMPTY"] == "1" {
                store.set("", forKey: "vocabulary")
                store.set(try? JSONEncoder().encode([Snippet]()), forKey: "snippets")
            }
            return store
        }()
        static var notesDirectory: URL {
            FileManager.default.temporaryDirectory.appending(
                path: "Pressay-DesignReview-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        static func populate(_ coordinator: AppCoordinator) {
            guard ProcessInfo.processInfo.environment["PRESSAY_REVIEW_EMPTY"] != "1" else { return }
            let excerpts = [
                "Could we move the review to Thursday? I’d like a little more time to work through the details. We can collect feedback tomorrow and send an updated version before the meeting.",
                "Thanks for sending this over. I’ll take a look this afternoon and get back to you with a few thoughts. I’ll flag anything that needs a decision before our next check-in.",
                "For the next iteration, focus on the setup experience. Keep permissions together, make the talk key easy to find, and leave advanced options in settings.",
                "The latest build is ready to review. Please check dictation in Mail and Notes, and let me know if you notice any formatting or microphone issues.",
                "Thursday at 10 works for me. I’ll bring the updated designs and a short list of open questions so we can make the remaining decisions together.",
                "Follow up after the review: update the setup copy, confirm the keyboard shortcut, and check the empty states in both light and dark appearance.",
            ]
            for (i, text) in excerpts.enumerated() {
                try? coordinator.history.add(
                    .init(
                        createdAt: .now.addingTimeInterval(-Double(i) * 3600), duration: 12 + Double(i),
                        targetBundleID: ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Notes"][i % 3],
                        engine: "Orukeet", rawTranscript: text, polishedText: text, asrLatency: 0.2, polishLatency: 0,
                        totalLatency: 0.2, audioPath: nil, usedLanguageModel: false))
            }
            for title in ["Product review", "Design sync", "Weekly planning"] {
                var note = Note(
                    kind: .meeting, title: title,
                    body:
                        "## Summary\nReview the setup experience and prepare the next build.\n\n## Action items\n- [ ] Review the setup flow before Thursday. (me)\n- [ ] Share the updated designs. (me)\n- [ ] Check the remaining copy. (Alex)",
                    transcripts: [],
                    lines: [
                        .init(speaker: .me, start: 0, text: "Let’s start with the first-time experience."),
                        .init(
                            speaker: .others, start: 4, text: "I think we should keep the setup to a few simple steps."),
                    ], duration: 1920)
                note.participants = ["Alex", "Maya"]
                note.speakerNames = ["Alex"]
                note.myNotes = "Review the setup flow before Thursday.\n\nKeep the first step simple."
                coordinator.notes.add(note)
            }
        }
    }
#endif
