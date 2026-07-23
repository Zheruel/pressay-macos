import Foundation
import PressayCore

/// Vocabulary rules the tuner derived from transcripts, with a blocklist for
/// deleted rules. Rules persist as long as their heard term keeps appearing
/// in transcripts; the daily pass refreshes `lastSeenAt` and expires rules
/// unused for `LearnedRuleRetention.unusedLifetime`.
@MainActor
final class LearnedVocabularyStore: ObservableObject {
    struct Record: Codable, Equatable, Sendable {
        let heard: String
        let preferred: String
        let count: Int
        let source: String
        let learnedAt: Date
        /// Optional so records persisted before the field existed decode;
        /// they fall back to `learnedAt`.
        var lastSeenAt: Date?

        var effectiveLastSeen: Date { lastSeenAt ?? learnedAt }
    }

    private enum Key {
        static let rules = "vocabularyTuner.rules"
        static let blocklist = "vocabularyTuner.blocklist"
        static let lastDetRun = "vocabularyTuner.lastDetRun"
        static let lastK3Run = "vocabularyTuner.lastK3Run"
        static let seenCandidates = "vocabularyTuner.seenCandidates"
        static let schemaVersion = "vocabularyTuner.schemaVersion"
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var blocklist: Set<String> = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    var lastDetRun: Date? {
        get { defaults.object(forKey: Key.lastDetRun) as? Date }
        set { defaults.set(newValue, forKey: Key.lastDetRun) }
    }

    var lastK3Run: Date? {
        get { defaults.object(forKey: Key.lastK3Run) as? Date }
        set { defaults.set(newValue, forKey: Key.lastK3Run) }
    }

    var seenCandidates: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.seenCandidates) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.seenCandidates) }
    }

    var entries: [VocabularyParser.Entry] {
        records.map { VocabularyParser.Entry(preferred: $0.preferred, aliases: [$0.heard]) }
    }

    /// Daily-pass semantics: incoming det rules insert or refresh; every
    /// existing rule whose heard term still occurs in the transcript window
    /// gets `lastSeenAt` bumped; rules unused past the retention lifetime
    /// expire. `heard` is the identity everywhere (SwiftUI row IDs, remove(),
    /// the blocklist), so an incoming heard term takes over its record.
    func applyDailyPass(detRules: [LearnedRule], heardTermsInWindow: Set<String>, now: Date = .now) {
        let incoming = detRules.filter { !blocklist.contains($0.heard.lowercased()) }
        let incomingByHeard = Dictionary(
            incoming.map { ($0.heard.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var updated: [Record] = []
        for record in records where !blocklist.contains(record.heard.lowercased()) {
            let fold = record.heard.lowercased()
            if let rule = incomingByHeard[fold] {
                updated.append(Record(
                    heard: record.heard, preferred: rule.preferred, count: rule.count,
                    source: record.source, learnedAt: record.learnedAt, lastSeenAt: now
                ))
            } else if heardTermsInWindow.contains(fold) {
                var bumped = record
                bumped.lastSeenAt = now
                updated.append(bumped)
            } else if !LearnedRuleRetention.isExpired(lastSeen: record.effectiveLastSeen, now: now) {
                updated.append(record)
            }
        }
        let known = Set(updated.map { $0.heard.lowercased() })
        updated += incoming
            .filter { !known.contains($0.heard.lowercased()) }
            .map {
                Record(
                    heard: $0.heard, preferred: $0.preferred, count: $0.count,
                    source: LearnedRule.Source.det.rawValue, learnedAt: now, lastSeenAt: now
                )
            }
        records = updated
        persist()
    }

    /// Adds one source's new rules on top of its existing ones and returns
    /// only the rules that were genuinely new — blocklisted and already-known
    /// heard terms don't count, so callers can't celebrate a no-op. The K3
    /// judge only sees never-before-seen candidates, so replacement semantics
    /// would silently wipe every rule learned in earlier K3 runs.
    @discardableResult
    func mergeRules(_ rules: [LearnedRule], source: LearnedRule.Source) -> [LearnedRule] {
        let incoming = rules.filter { !blocklist.contains($0.heard.lowercased()) }
        let knownHeard = Set(records.map { $0.heard.lowercased() })
        let incomingHeard = Set(incoming.map { $0.heard.lowercased() })
        let kept = records.filter {
            !incomingHeard.contains($0.heard.lowercased()) && !blocklist.contains($0.heard.lowercased())
        }
        records = kept + incoming.map {
            Record(
                heard: $0.heard, preferred: $0.preferred, count: $0.count,
                source: source.rawValue, learnedAt: .now, lastSeenAt: .now
            )
        }
        persist()
        return incoming.filter { !knownHeard.contains($0.heard.lowercased()) }
    }

    func remove(_ record: Record) {
        blocklist.insert(record.heard.lowercased())
        records.removeAll { $0.heard.lowercased() == record.heard.lowercased() }
        persist()
    }

    func isCovered(_ term: String) -> Bool {
        records.contains { $0.heard.caseInsensitiveCompare(term) == .orderedSame }
    }

    private func reload() {
        if let data = defaults.data(forKey: Key.rules),
           let decoded = try? JSONDecoder().decode([Record].self, from: data) {
            records = decoded
        }
        blocklist = Set(defaults.stringArray(forKey: Key.blocklist) ?? [])
        migrateIfNeeded()
    }

    private func migrateIfNeeded() {
        guard defaults.integer(forKey: Key.schemaVersion) < LearnedRuleMigration.schemaVersion else {
            return
        }
        let surviving = records.filter { LearnedRuleMigration.survivesV1(source: $0.source) }
        if surviving.count != records.count {
            records = surviving
            persist()
        }
        // Rebuild det rules from history on next launch instead of in 24h.
        defaults.removeObject(forKey: Key.lastDetRun)
        defaults.set(LearnedRuleMigration.schemaVersion, forKey: Key.schemaVersion)
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(records), forKey: Key.rules)
        defaults.set(Array(blocklist), forKey: Key.blocklist)
    }
}
