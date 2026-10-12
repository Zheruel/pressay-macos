import Foundation
import PressayCore

/// On-device vocabulary tuning: a daily matcher pass over recent transcripts plus an instant pass per dictation.
@MainActor
final class VocabularyTunerRunner: ObservableObject {
    private static let detInterval: TimeInterval = 24 * 3_600

    /// Cheap to call often; the date gate decides whether work happens.
    func scheduleIfNeeded(history: HistoryStore, settings: AppSettings) {
        let store = settings.learnedVocabulary
        let due = { (date: Date?) in date.map { Date().timeIntervalSince($0) > Self.detInterval } ?? true }
        guard due(store.lastDetRun) || due(settings.vocabularySuggestions.lastMined) else { return }
        runPass(history: history, settings: settings)
    }

    /// The scan is too heavy for the main actor; only store mutations hop back.
    private func runPass(history: HistoryStore, settings: AppSettings) {
        let texts = history.records.map(\.rawTranscript)
        guard !texts.isEmpty else { return }
        let anchors = Self.anchors(settings: settings)
        let heardTerms = Set(settings.learnedVocabulary.records.map { $0.heard.lowercased() })
        let dictations = history.records.map {
            VocabularyDiscovery.Dictation(
                raw: $0.rawTranscript, polished: $0.polishedText,
                date: $0.createdAt, usedLanguageModel: $0.usedLanguageModel
            )
        }
        let known = settings.knownVocabularyFolds
        Task.detached(priority: .utility) { [weak self] in
            let candidates = VocabularyTuner.candidates(in: texts, minimumCount: 1, anchors: anchors)
            let suggestions = VocabularyDiscovery.suggestions(from: dictations, known: known)
            // rawTranscript is pre-correction, so active mishearings still recur in it.
            let windowText = texts.joined(separator: "\n").lowercased()
            let seenHeard = heardTerms.filter { windowText.contains($0) }
            await MainActor.run { [weak self] in
                self?.runDeterministic(
                    candidates: candidates, anchors: anchors,
                    heardTermsInWindow: seenHeard, settings: settings
                )
                settings.vocabularySuggestions.replaceMined(suggestions, known: settings.knownVocabularyFolds)
            }
        }
    }

    /// Runs on the dictation path so the transcript that introduced a mishearing is already corrected.
    @discardableResult
    func learnImmediately(from transcript: String, settings: AppSettings) -> [LearnedRule] {
        let anchors = Self.anchors(settings: settings)
        let rules = VocabularyTuner.incrementalRules(for: transcript, anchors: anchors)
        guard !rules.isEmpty else { return [] }
        let store = settings.learnedVocabulary
        let known = Set(store.records.map { $0.heard.lowercased() })
        let fresh = rules.filter { !known.contains($0.heard.lowercased()) }
        guard !fresh.isEmpty else { return [] }
        return store.mergeRules(fresh, source: .det)
    }

    private func runDeterministic(
        candidates: [TunerCandidate],
        anchors: [String],
        heardTermsInWindow: Set<String>,
        settings: AppSettings
    ) {
        let store = settings.learnedVocabulary
        // User and old-judge rules outrank the matcher.
        let k3Heard = Set(
            store.records
                .filter { $0.source != LearnedRule.Source.det.rawValue }
                .map { $0.heard.lowercased() }
        )
        let rules = VocabularyTuner.deterministicRules(candidates: candidates, anchors: anchors)
            .filter { !k3Heard.contains($0.heard.lowercased()) }
        store.applyDailyPass(detRules: rules, heardTermsInWindow: heardTermsInWindow)
        store.lastDetRun = .now
    }

    static func anchors(settings: AppSettings) -> [String] {
        var seen = Set<String>()
        let terms = VocabularyParser.parse(settings.vocabularySource).map(\.preferred)
            + settings.learnedVocabulary.records.map(\.preferred)
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }
}
