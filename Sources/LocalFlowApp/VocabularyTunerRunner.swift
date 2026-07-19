import Foundation
import LocalFlowCore

/// Background vocabulary tuning: the deterministic matcher passes daily; the
/// Kimi judge runs with a key, ≥3 new unseen candidates, and a 3-day gap.
@MainActor
final class VocabularyTunerRunner: ObservableObject {
    enum Status: Equatable {
        case idle
        case running
        case done(Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let client = KimiTunerClient()
    private var task: Task<Void, Never>?

    private static let detInterval: TimeInterval = 24 * 3_600
    private static let k3Interval: TimeInterval = 24 * 3_600
    private static let k3NewCandidateFloor = 3

    var onLearned: (([LearnedRule]) -> Void)?

    /// Cheap to call often; gates decide whether work happens. The date gates
    /// run before the keychain read so the securityd IPC is skipped on the
    /// common nothing-due path.
    func scheduleIfNeeded(history: HistoryStore, settings: AppSettings) {
        let store = settings.learnedVocabulary
        let detDue = store.lastDetRun.map { Date().timeIntervalSince($0) > Self.detInterval } ?? true
        let k3DateDue = store.lastK3Run.map { Date().timeIntervalSince($0) > Self.k3Interval } ?? true
        guard detDue || k3DateDue else { return }
        let k3Due = k3DateDue && KimiAPIKeyStore.read() != nil
        guard detDue || k3Due else { return }
        runPasses(
            history: history, settings: settings,
            detDue: detDue, k3Due: k3Due, k3Floor: Self.k3NewCandidateFloor
        )
    }

    /// Settings "Optimize now": deterministic always, K3 when a key exists.
    func runNow(history: HistoryStore, settings: AppSettings) {
        runPasses(
            history: history, settings: settings,
            detDue: true, k3Due: KimiAPIKeyStore.read() != nil, k3Floor: 1
        )
    }

    /// The candidate scan tokenizes and phonetically keys every stored
    /// transcript — far too heavy for the main actor, which is mid-insertion
    /// UI when this fires. Only the store mutations hop back.
    private func runPasses(
        history: HistoryStore,
        settings: AppSettings,
        detDue: Bool,
        k3Due: Bool,
        k3Floor: Int
    ) {
        let texts = history.records.map(\.rawTranscript)
        guard !texts.isEmpty else { return }
        let anchors = Self.anchors(settings: settings)
        Task.detached(priority: .utility) { [weak self] in
            let candidates = VocabularyTuner.candidates(in: texts, minimumCount: 1, anchors: anchors)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if detDue {
                    runDeterministic(candidates: candidates, anchors: anchors, settings: settings)
                }
                guard k3Due, let apiKey = KimiAPIKeyStore.read() else { return }
                let recurring = candidates.filter { $0.count >= 2 }
                let fresh = freshCandidates(recurring, settings: settings)
                if fresh.count >= k3Floor {
                    runK3(fresh: fresh, anchors: anchors, apiKey: apiKey, settings: settings)
                }
            }
        }
    }

    /// Runs on the dictation path so a mishearing of a known term is
    /// corrected in the very transcript that introduced it. Terms already
    /// owned by a rule (especially LLM-vetted K3 ones) are left untouched.
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

    private func runDeterministic(candidates: [TunerCandidate], anchors: [String], settings: AppSettings) {
        let store = settings.learnedVocabulary
        let k3Heard = Set(
            store.records
                .filter { $0.source == LearnedRule.Source.k3.rawValue }
                .map { $0.heard.lowercased() }
        )
        let rules = VocabularyTuner.deterministicRules(candidates: candidates, anchors: anchors)
            .filter { !k3Heard.contains($0.heard.lowercased()) }
        store.replaceRules(rules, source: .det)
        store.lastDetRun = .now
    }

    private func freshCandidates(_ candidates: [TunerCandidate], settings: AppSettings) -> [TunerCandidate] {
        let store = settings.learnedVocabulary
        return candidates.filter {
            !store.seenCandidates.contains($0.term.lowercased()) && !store.isCovered($0.term)
        }
    }

    private func runK3(fresh: [TunerCandidate], anchors: [String], apiKey: String, settings: AppSettings) {
        guard status != .running else { return }
        status = .running
        // Close the 3-day gate at attempt start: gating on success would retry
        // the network judge after every dictation while the key is bad, the
        // network is down, or dictations arrive faster than the round trip.
        settings.learnedVocabulary.lastK3Run = .now
        task = Task { [weak self, client] in
            do {
                let findings = try await client.judge(candidates: fresh, anchors: anchors, apiKey: apiKey)
                guard !Task.isCancelled else {
                    self?.status = .idle
                    return
                }
                let counts = Dictionary(uniqueKeysWithValues: fresh.map { ($0.term, $0.count) })
                let rules = VocabularyTuner.anchorFilteredRules(
                    findings: findings.map { ($0.heard, $0.meant) },
                    anchors: anchors,
                    counts: counts
                )
                let store = settings.learnedVocabulary
                var seen = store.seenCandidates
                fresh.forEach { seen.insert($0.term.lowercased()) }
                store.seenCandidates = seen
                let added = store.mergeRules(rules, source: .k3)
                if !added.isEmpty { self?.onLearned?(added) }
                self?.status = .done(rules.count)
            } catch {
                self?.status = .failed(error.localizedDescription)
            }
        }
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
