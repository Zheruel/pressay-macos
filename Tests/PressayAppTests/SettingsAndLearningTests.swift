import Foundation
import Testing

@testable import PressayApp
@testable import PressayCore

@MainActor
struct SettingsAndLearningTests {
    private func isolated(_ body: (UserDefaults) -> Void) {
        let name = "PressayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func languageSelectionsMigrateAgainstEachModelsCapabilities() {
        isolated { defaults in
            defaults.set("qwen3ASR17", forKey: "asrModel")
            defaults.set(TranscriptionLanguage.japanese.rawValue, forKey: "language")
            defaults.set("whisperTurboGGML", forKey: "meetingASRModel")
            defaults.set(TranscriptionLanguage.croatian.rawValue, forKey: "meetingLanguage")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.language == .auto)
            #expect(settings.meetingLanguage == .croatian)
            #expect(settings.asrModel.languageCodes.contains("ja"))
        }
    }

    @Test func retiredMicrophoneAndStylePreferencesCannotEnableRemovedFeatures() {
        isolated { defaults in
            defaults.set(true, forKey: "keepMicWarm")
            defaults.set(true, forKey: "matchAppStyle")
            _ = AppSettings(defaults: defaults)
            #expect(defaults.object(forKey: "keepMicWarm") == nil)
            #expect(defaults.object(forKey: "matchAppStyle") == nil)
        }
    }

    @Test func uncertainCorrectionsNeedConsistentEvidence() {
        isolated { defaults in
            let store = LearnedVocabularyStore(defaults: defaults)
            let correction = VocabularyCorrection(heard: "fig ma", typed: "Figma", isStrong: false)
            store.observe([correction, correction])
            #expect(store.records.isEmpty)
            store.observe([correction])
            #expect(store.entries == [.init(preferred: "Figma", aliases: ["fig ma"])])
        }
    }

    @Test func contradictoryUserCorrectionRetractsTheOldMapping() {
        isolated { defaults in
            let store = LearnedVocabularyStore(defaults: defaults)
            store.mergeRules([.init(heard: "superbase", preferred: "Supabase", count: 2, source: .edit)], source: .edit)
            store.observe([.init(heard: "Supabase", typed: "Superbase", isStrong: true)])
            #expect(!store.isCovered("superbase"))
            #expect(store.records.contains { $0.preferred == "Superbase" })
        }
    }

    @Test func explicitRemovalSurvivesNewAutomaticSpellingsAndRelaunch() {
        isolated { defaults in
            let store = LearnedVocabularyStore(defaults: defaults)
            store.block(preferred: "Figma")
            let reopened = LearnedVocabularyStore(defaults: defaults)
            reopened.mergeRules(
                [.init(heard: "fig mah", preferred: "Figma", count: 4, source: .suggestion)], source: .suggestion)
            #expect(reopened.records.isEmpty)
        }
    }

    @Test func dismissedSuggestionsBecomePersistentAutomaticLearningExclusions() {
        isolated { defaults in
            defaults.set(["fig ma→figma"], forKey: "vocabularySuggestions.dismissed")
            let store = LearnedVocabularyStore(defaults: defaults)
            store.mergeRules(
                [.init(heard: "fig mah", preferred: "Figma", count: 4, source: .suggestion)], source: .suggestion)
            #expect(store.records.isEmpty)
            #expect(defaults.object(forKey: "vocabularySuggestions.dismissed") == nil)
        }
    }

    @Test func englishFormattingDoesNotDamageLegitimateForeignRepetitions() {
        let text = "Nous nous retrouvons jeudi pour revoir les notes de la réunion."
        #expect(!SpeechLanguage.usesEnglishRules(text))
        #expect(!SpeechLanguage.usesEnglishRules(text, hint: .french))
        #expect(DeterministicPromptCleaner.clean(text, englishRules: false) == text)
        #expect(SpeechLanguage.usesEnglishRules("um please send the meeting notes before Thursday afternoon"))
    }

    @Test func disablingLearningStopsTheImmediateBackgroundMatcher() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.vocabularySource = "Supabase"
            settings.learnFromEdits = false
            let runner = VocabularyTunerRunner()
            #expect(runner.learnImmediately(from: "connect superbase", settings: settings).isEmpty)
            #expect(settings.learnedVocabulary.records.isEmpty)
        }
    }
}
