import Foundation
import Testing
@testable import PressayCore

struct VoicesTests {
    private func others(_ start: TimeInterval, _ end: TimeInterval, _ text: String = "x") -> TranscriptLine {
        TranscriptLine(speaker: .others, start: start, text: text, end: end)
    }

    @Test func linesGoToTheVoiceThatSpokeMost() {
        let lines = [
            others(0, 4),
            TranscriptLine(speaker: .me, start: 5, text: "me", end: 6),
            others(7, 12),
            others(13, 15),
        ]
        let turns = [
            VoiceTurn(start: 0, end: 4.2, speaker: 3),
            VoiceTurn(start: 6.8, end: 8, speaker: 3),
            VoiceTurn(start: 8, end: 12, speaker: 0),
            VoiceTurn(start: 13, end: 15, speaker: 3),
        ]
        let labelled = VoiceLabeler.label(lines, turns: turns)
        // Numbered by first appearance, not by the diarizer's index.
        #expect(labelled.map(\.voice) == [1, nil, 2, 1])
    }

    @Test func oneVoiceStaysOthers() {
        let lines = [others(0, 4), others(5, 9)]
        let turns = [VoiceTurn(start: 0, end: 9, speaker: 2)]
        #expect(VoiceLabeler.label(lines, turns: turns) == lines)
    }

    @Test func linesWithoutOverlapStayUnlabelled() {
        let lines = [others(0, 4), others(5, 9), others(20, 22)]
        let turns = [VoiceTurn(start: 0, end: 4, speaker: 0), VoiceTurn(start: 5, end: 9, speaker: 1)]
        #expect(VoiceLabeler.label(lines, turns: turns).map(\.voice) == [1, 2, nil])
    }

    @Test func labelsUseNamesThenSpeakerNumbers() {
        let line = TranscriptLine(speaker: .others, start: 61, text: "Hi", voice: 2)
        #expect(line.voiceLabel(names: []) == "Speaker 2")
        #expect(line.voiceLabel(names: ["Priya", " "]) == "Speaker 2")
        #expect(line.voiceLabel(names: ["", "Tomasz"]) == "Tomasz")
        #expect(line.plain(names: ["", "Tomasz"]) == "[1:01] Tomasz: Hi")
        #expect(TranscriptLine(speaker: .others, start: 0, text: "Hi").plain() == "[0:00] Others: Hi")
        #expect(TranscriptLine(speaker: .me, start: 0, text: "Hi", voice: 1).voiceLabel(names: []) == nil)
    }

    @Test func oldLinesDecodeWithoutVoices() throws {
        let json = #"{"speaker":"others","start":3,"text":"Yes."}"#
        let line = try JSONDecoder().decode(TranscriptLine.self, from: Data(json.utf8))
        #expect(line.voice == nil && line.end == nil)
    }

    @Test func writeUpExplainsSpeakerLabels() {
        let lines = [TranscriptLine(speaker: .others, start: 0, text: "Hi", voice: 1)]
        let user = MeetingPrompt.user(lines: lines, speakerNames: ["Priya"])
        #expect(user.contains("told apart automatically"))
        #expect(user.contains("] Priya: Hi"))
        #expect(!MeetingPrompt.user(lines: [TranscriptLine(speaker: .others, start: 0, text: "Hi")]).contains("told apart"))
    }

    @Test func reviewKeepsOnlyNamesTheTranscriptSupports() {
        let lines = [
            TranscriptLine(speaker: .me, start: 0, text: "Tomasz, you want to go first?"),
            TranscriptLine(speaker: .others, start: 2, text: "Sure, so this week I", voice: 1),
            TranscriptLine(speaker: .others, start: 9, text: "Hi, Priya here", voice: 2),
            TranscriptLine(speaker: .others, start: 12, text: "Thanks", voice: 3),
        ]
        let reply = """
        Here you go: {"speakers": {"1": "Tomasz", "2": "Priya", "3": "Gregory", "4": "Ana", "x": "Bo"}, "fixes": []}
        """
        let parse = { TranscriptReview.parse($0, lines: lines, participants: $1).names }
        #expect(parse(reply, []) == [1: "Tomasz", 2: "Priya"])
        // A participant the user typed counts even when unheard.
        #expect(parse(#"{"speakers": {"3": "gregory"}}"#, ["Gregory"]) == [3: "gregory"])
        // Two voices with one name: name neither.
        #expect(parse(#"{"speakers": {"1": "Priya", "2": "Priya"}}"#, []).isEmpty)
        #expect(parse("I can't tell.", []).isEmpty)
    }

    @Test func fixesApplyToWholeWordsOnlyAndMustOccur() {
        let lines = [
            TranscriptLine(speaker: .others, start: 0, text: "Kubernetis is down, also the remold.", voice: 1),
            TranscriptLine(speaker: .me, start: 4, text: "Restart Kubernetis then."),
        ]
        let reply = #"{"fixes": [{"from": "Kubernetis", "to": "Kubernetes"}, {"from": "the remold", "to": "the remote"}, {"from": "al", "to": "Al"}, {"from": "never said", "to": "x"}, {"from": "down", "to": "down"}]}"#
        let fixes = TranscriptReview.parse(reply, lines: lines, participants: []).fixes
        #expect(fixes == [.init(from: "Kubernetis", to: "Kubernetes"), .init(from: "the remold", to: "the remote")])
        let fixed = TranscriptReview.apply(fixes + [.init(from: "al", to: "Al")], to: lines)
        #expect(fixed.map(\.text) == ["Kubernetes is down, also the remote.", "Restart Kubernetes then."])
        #expect(fixed[0].voice == 1)
    }
}
