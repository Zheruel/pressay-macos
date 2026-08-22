import Foundation
import PressayCore

/// Background vocabulary tuning: a deterministic pass scans recent
/// transcripts for phonetic mishearings of known terms and learns fixes,
/// fully on-device.
@MainActor
final class VocabularyTunerRunner: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case done(Int)
    }

    @Published private(set) var status: Status = .idle

    private static let detInterval: TimeInterval = 24 * 3_600

    var onLearned: (([LearnedRule]) -> Void)?

    /// Cheap to call often; the date gate decides whether work happens.
    func scheduleIfNeeded(history: HistoryStore, settings: AppSettings) {
        let store = settings.learnedVocabulary
        let detDue = store.lastDetRun.map { Date().timeIntervalSince($0) > Self.detInterval } ?? true
        guard detDue else { return }
        runPasses(history: history, settings: settings)
    }

    /// Settings "Optimize now".
    func runNow(history: HistoryStore, settings: AppSettings) {
        runPasses(history: history, settings: settings)
    }

    /// The candidate scan tokenizes and phonetically keys every stored
    /// transcript — far too heavy for the main actor, which is mid-insertion
    /// UI when this fires. Only the store mutation hops back.
    private func runPasses(history: HistoryStore, settings: AppSettings) {
        let texts = history.records.map(\.rawTranscript)
        guard !texts.isEmpty else { return }
        let anchors = Self.anchors(settings: settings)
        let heardTerms = Set(settings.learnedVocabulary.records.map { $0.heard.lowercased() })
        status = .running
        Task.detached(priority: .utility) { [weak self] in
            let candidates = VocabularyTuner.candidates(in: texts, minimumCount: 1, anchors: anchors)
            // Which learned heard terms still occur in the window: keeps
            // their rules alive (substring match over the raw transcripts;
            // rawTranscript is pre-correction, so active mishearings recur).
            let windowText = texts.joined(separator: "\n").lowercased()
            let seenHeard = heardTerms.filter { windowText.contains($0) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                runDeterministic(
                    candidates: candidates, anchors: anchors,
                    heardTermsInWindow: seenHeard, settings: settings
                )
            }
        }
    }

    /// Runs on the dictation path so a mishearing of a known term is
    /// corrected in the very transcript that introduced it. Terms already
    /// owned by a rule (especially a legacy LLM-vetted one) are left untouched.
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
        // Never let the deterministic pass overwrite a rule a legacy cloud
        // judge already vetted, if one still exists from before its removal.
        let k3Heard = Set(
            store.records
                .filter { $0.source == LearnedRule.Source.k3.rawValue }
                .map { $0.heard.lowercased() }
        )
        let rules = VocabularyTuner.deterministicRules(candidates: candidates, anchors: anchors)
            .filter { !k3Heard.contains($0.heard.lowercased()) }
        store.applyDailyPass(detRules: rules, heardTermsInWindow: heardTermsInWindow)
        store.lastDetRun = .now
        status = .done(rules.count)
    }

    /// Anchors: curated preferred terms, the user's own entries, and
    /// everything learned so far (learned truth compounds).
    static func anchors(settings: AppSettings) -> [String] {
        var seen = Set<String>()
        let terms = VocabularyParser.parse(settings.vocabularySource).map(\.preferred)
            + settings.learnedVocabulary.records.map(\.preferred)
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }
}
