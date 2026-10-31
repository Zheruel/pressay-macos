import Foundation
import Testing

@testable import PressayApp
@testable import PressayCore

@MainActor
struct SettingsAndVocabularyTests {
    private func isolated(_ body: (UserDefaults) -> Void) {
        let name = "PressayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func cleanupConnectionsPreserveExistingDefaultsAndIgnoreOldModels() {
        isolated { defaults in
            defaults.set("sonnet55", forKey: "claudeCleanupModel")
            defaults.set("arbitrary-legacy-model", forKey: "chatGPTModel")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.cleanupProvider == .claude)
            #expect(settings.claudeConnection == .apiKey)
            #expect(settings.openAIConnection == .subscription)
            defaults.set("chatgpt", forKey: "cleanupProvider")
            let reopened = AppSettings(defaults: defaults)
            #expect(reopened.cleanupProvider == .chatgpt)
        }
    }

    @Test func cleanupConnectionsPersistIndependently() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.claudeConnection = .subscription
            settings.openAIConnection = .apiKey
            settings.cleanupProvider = .chatgpt
            settings.notesModel = "claude:sonnet55"
            let reopened = AppSettings(defaults: defaults)
            #expect(reopened.claudeConnection == .subscription)
            #expect(reopened.openAIConnection == .apiKey)
            #expect(reopened.cleanupProvider == .chatgpt)
            #expect(reopened.notesModel == "claude:sonnet55")
        }
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
        }
    }

    @Test func freshDictionaryIsEmptyAndManualAliasesSurviveRelaunch() {
        isolated { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.vocabularySource.isEmpty)
            #expect(settings.vocabularyEntries.isEmpty)
            settings.addVocabularyWord("Project Aurora", aliases: ["project a roar a"])
            let reopened = AppSettings(defaults: defaults)
            #expect(reopened.vocabularyEntries == [.init(preferred: "Project Aurora", aliases: ["project a roar a"])])
            reopened.vocabularySource = ""
            #expect(AppSettings(defaults: defaults).vocabularyEntries.isEmpty)
        }
    }

    @Test func everyBundledDictionaryIsRetiredButCustomEntriesSurvive() {
        for stock in VocabularyMigration.bundledSources {
            isolated { defaults in
                defaults.set(stock, forKey: "vocabulary")
                #expect(AppSettings(defaults: defaults).vocabularyEntries.isEmpty)
            }
            isolated { defaults in
                defaults.set(stock + "\n\n# Custom\nFigma <= fig ma\nClaude", forKey: "vocabulary")
                let expected: [VocabularyParser.Entry] = [
                    .init(preferred: "Figma", aliases: ["fig ma"]),
                    .init(preferred: "Claude", aliases: [])
                ]
                #expect(AppSettings(defaults: defaults).vocabularyEntries == expected)
            }
        }
    }

    @Test func editedStockKeepsCustomAliasesAndUnrecognizedManualLists() {
        isolated { defaults in
            let stock = VocabularyMigration.bundledSources[0]
                .replacingOccurrences(of: "Kimi <= kimmy, akimi", with: "Kimi <= my custom spelling")
                .replacingOccurrences(of: "Slack\n", with: "")
            defaults.set(stock, forKey: "vocabulary")
            #expect(AppSettings(defaults: defaults).vocabularyEntries == [
                .init(preferred: "Kimi", aliases: ["my custom spelling"])
            ])
        }
        isolated { defaults in
            defaults.set("Claude\nMy Project <= my pro ject", forKey: "vocabulary")
            #expect(AppSettings(defaults: defaults).vocabularyTerms == ["Claude", "My Project"])
        }
    }

    @Test func stockMigrationRunsOnlyOnceAndRetiresAutomaticState() {
        isolated { defaults in
            let retired = ["learnFromEdits", "vocabularyTuner.rules", "vocabularyTuner.blocklist",
                "vocabularyTuner.lastDetRun", "vocabularyTuner.lastK3Run", "vocabularyTuner.seenCandidates",
                "vocabularyTuner.schemaVersion", "vocabularySuggestions.dismissed",
                "vocabularySuggestions.pending", "vocabularySuggestions.lastMined"]
            for key in retired { defaults.set("legacy", forKey: key) }
            let settings = AppSettings(defaults: defaults)
            #expect(settings.vocabularyEntries.isEmpty)
            for key in retired { #expect(defaults.object(forKey: key) == nil) }
            // Even a former stock list is legitimate if explicitly added after migration.
            settings.vocabularySource = VocabularyMigration.bundledSources[0]
            #expect(AppSettings(defaults: defaults).vocabularySource == settings.vocabularySource)
        }
    }

    @Test func englishFormattingDoesNotDamageLegitimateForeignRepetitions() {
        let text = "Nous nous retrouvons jeudi pour revoir les notes de la réunion."
        #expect(!SpeechLanguage.usesEnglishRules(text))
        #expect(!SpeechLanguage.usesEnglishRules(text, hint: .french))
        #expect(DeterministicPromptCleaner.clean(text, englishRules: false) == text)
        #expect(SpeechLanguage.usesEnglishRules("um please send the meeting notes before Thursday afternoon"))
    }

}
