import Foundation
@testable import PressayCore
import Testing

struct NotesModelTests {
    @Test func idRoundTrips() {
        for model in NotesModel.options(claude: true, chatGPT: true) {
            #expect(NotesModel(id: model.id) == model)
        }
        #expect(NotesModel(id: "claude:nope") == nil)
        #expect(NotesModel(id: "") == nil)
    }

    @Test func optionsFollowSetUpProviders() {
        #expect(NotesModel.options(claude: false, chatGPT: false).isEmpty)
        #expect(NotesModel.options(claude: true, chatGPT: false).allSatisfy { !$0.isChatGPT })
        #expect(NotesModel.options(claude: false, chatGPT: true).allSatisfy { $0.isChatGPT })
    }

    @Test func resolveKeepsAvailableChoiceAndFallsBack() {
        let sonnet = NotesModel.claude(.sonnet55)
        #expect(NotesModel.resolve(stored: sonnet.id, preferChatGPT: true, claude: true, chatGPT: true) == sonnet)
        // Stored provider signed out: the recommended model of what remains.
        #expect(NotesModel.resolve(stored: sonnet.id, preferChatGPT: false, claude: false, chatGPT: true)
            == .chatgpt(ChatGPTCleanupModel.defaultSlug))
        #expect(NotesModel.resolve(stored: "", preferChatGPT: true, claude: true, chatGPT: true)
            == .chatgpt(ChatGPTCleanupModel.defaultSlug))
        #expect(NotesModel.resolve(stored: nil, preferChatGPT: true, claude: true, chatGPT: false) == .claude(.haiku55))
        #expect(NotesModel.resolve(stored: nil, preferChatGPT: false, claude: false, chatGPT: false) == nil)
    }
}

struct CallDetectionTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func briefMicUseIsNotACall() {
        var state = CallDetectionState()
        #expect(state.update(activeApps: ["Zoom"], at: t0) == nil)
        #expect(state.update(activeApps: ["Zoom"], at: t0 + 2) == nil)
        #expect(state.update(activeApps: [], at: t0 + 3) == nil)
        #expect(state.update(activeApps: ["Zoom"], at: t0 + 5) == nil)
    }

    @Test func startsAndEndsAfterHysteresis() {
        var state = CallDetectionState()
        _ = state.update(activeApps: ["Zoom"], at: t0)
        #expect(state.update(activeApps: ["Zoom"], at: t0 + 4) == .started(app: "Zoom"))
        #expect(state.update(activeApps: ["Zoom"], at: t0 + 6) == nil)
        // A short mute does not end the call.
        #expect(state.update(activeApps: [], at: t0 + 8) == nil)
        #expect(state.update(activeApps: ["Zoom"], at: t0 + 12) == nil)
        #expect(state.update(activeApps: [], at: t0 + 14) == nil)
        #expect(state.update(activeApps: [], at: t0 + 24) == .ended)
        #expect(state.update(activeApps: [], at: t0 + 40) == nil)
    }

    @Test func knownAppsAndHelpers() {
        #expect(CallApps.name(forBundleID: "us.zoom.xos") == "Zoom")
        #expect(CallApps.name(forBundleID: "com.google.Chrome.helper") == "Google Chrome")
        #expect(CallApps.name(forBundleID: "com.google.Chromebook") == nil)
        #expect(CallApps.name(forBundleID: "com.apple.VoiceMemos") == nil)
    }
}

struct MeetingAskPromptTests {
    private func meeting(_ title: String, transcript: String) -> MeetingAskPrompt.Meeting {
        .init(title: title, date: Date(timeIntervalSince1970: 0), notes: "## Summary\nok", myNotes: "", transcript: transcript)
    }

    @Test func transcriptsFitTheBudgetNewestFirst() {
        let prompt = MeetingAskPrompt.user(
            question: "What did we decide?",
            meetings: [meeting("New", transcript: String(repeating: "a", count: 80)), meeting("Old", transcript: String(repeating: "b", count: 80))],
            transcriptBudget: 100
        )
        #expect(prompt.contains(String(repeating: "a", count: 80)))
        #expect(!prompt.contains(String(repeating: "b", count: 80)))
        #expect(prompt.contains("<meeting title=\"Old\""))
        #expect(prompt.hasSuffix("<question>\nWhat did we decide?\n</question>"))
        #expect(!prompt.contains("<my_notes>"))
        #expect(prompt.hasPrefix("<today>"))
        #expect(!prompt.contains("<conversation>"))
    }

    @Test func earlierExchangesComeBeforeTheQuestion() {
        let prompt = MeetingAskPrompt.user(
            question: "And who owns it?", meetings: [meeting("Sync", transcript: "Me: ship it")],
            history: [.init(question: "What did we decide?", answer: "To ship on Friday.")]
        )
        #expect(prompt.contains("<asked>\nWhat did we decide?\n</asked>\n<answered>\nTo ship on Friday.\n</answered>"))
        #expect(prompt.hasSuffix("<question>\nAnd who owns it?\n</question>"))
    }
}
