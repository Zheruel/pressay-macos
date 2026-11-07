import Foundation
import Testing

@testable import PressayApp

struct OnboardingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func realDictationMustReachThePracticeEditor() {
        let evidence = OnboardingDictationEvidence(text: "My words.", targetPID: 42,
            receivedAudio: true, inserted: true, completedAt: now)
        #expect(evidence.verifies(practiceText: "My words.\n", startedAt: now, appPID: 42))
        #expect(!evidence.verifies(practiceText: "", startedAt: now, appPID: 42))
        #expect(!evidence.verifies(practiceText: "A typed sample.", startedAt: now, appPID: 42))
        #expect(!evidence.verifies(practiceText: "My words.", startedAt: now, appPID: 43))
    }

    @Test func clipboardFallbackAndMissingAudioCannotFinishSetup() {
        for (audio, inserted) in [(false, true), (true, false), (false, false)] {
            let evidence = OnboardingDictationEvidence(text: "My words.", targetPID: 42,
                receivedAudio: audio, inserted: inserted, completedAt: now)
            #expect(!evidence.verifies(practiceText: "My words.", startedAt: now, appPID: 42))
        }
    }

    @Test func previousPracticeAndEmptyRecognitionCannotFinishSetup() {
        let stale = OnboardingDictationEvidence(text: "My words.", targetPID: 42,
            receivedAudio: true, inserted: true, completedAt: now.addingTimeInterval(-1))
        #expect(!stale.verifies(practiceText: "My words.", startedAt: now, appPID: 42))
        let empty = OnboardingDictationEvidence(text: " \n", targetPID: 42,
            receivedAudio: true, inserted: true, completedAt: now)
        #expect(!empty.verifies(practiceText: " \n", startedAt: now, appPID: 42))
    }
}
