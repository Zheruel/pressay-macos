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
        /// Optional so records persisted before the field existed decode; nil falls back to `learnedAt`.
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

    private var observations: [String: Int] = [:]
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
        let incoming = detRules.filter { !isBlocked(heard: $0.heard, preferred: $0.preferred) }
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

    /// Returns only genuinely new rules (not blocklisted or known). Additive, not replacing:
    /// the K3 judge only sees unseen candidates, so replacing would wipe earlier K3 rules.
    @discardableResult
    func mergeRules(_ rules: [LearnedRule], source: LearnedRule.Source) -> [LearnedRule] {
        let incoming = rules.filter { !isBlocked(heard: $0.heard, preferred: $0.preferred) }
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

    /// Explicitly removing a word prevents the background engine from adding it back.
    func block(preferred: String) {
        blocklist.insert("preferred:" + preferred.lowercased())
        for record in records where record.preferred.caseInsensitiveCompare(preferred) == .orderedSame {
            blocklist.insert(record.heard.lowercased())
        }
        records.removeAll { $0.preferred.caseInsensitiveCompare(preferred) == .orderedSame }
        persist()
    }

    func unblockPreferred(_ preferred: String) {
        blocklist.remove("preferred:" + preferred.lowercased())
        persist()
    }

    private func isBlocked(heard: String, preferred: String) -> Bool {
        blocklist.contains(heard.lowercased()) || blocklist.contains("preferred:" + preferred.lowercased())
    }

    func observe(_ corrections: [VocabularyCorrection]) {
        for correction in corrections {
            // A user correcting our learned spelling retracts that mapping.
            let contradicted = records.filter {
                $0.preferred.caseInsensitiveCompare(correction.heard) == .orderedSame
                    && $0.preferred.caseInsensitiveCompare(correction.typed) != .orderedSame
            }
            for record in contradicted { remove(record) }
            let key = correction.heard.lowercased() + "→" + correction.typed.lowercased()
            // Conflicting targets reset uncertain evidence rather than racing to a rule.
            observations = observations.filter { !$0.key.hasPrefix(correction.heard.lowercased() + "→") || $0.key == key }
            observations[key, default: 0] += 1
            if correction.isStrong || observations[key, default: 0] >= 3 {
                mergeRules([LearnedRule(heard: correction.heard, preferred: correction.typed,
                                       count: observations[key, default: 1], source: .edit)], source: .edit)
                observations[key] = nil
            }
        }
    }

    func unblock(_ heard: String) {
        guard blocklist.remove(heard.lowercased()) != nil else { return }
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
        // Preserve explicit dismissals from the retired suggestion queue.
        let dismissed = defaults.stringArray(forKey: "vocabularySuggestions.dismissed") ?? []
        if !dismissed.isEmpty {
            for id in dismissed {
                let parts = id.components(separatedBy: "→")
                if let preferred = parts.last, !preferred.isEmpty { blocklist.insert("preferred:" + preferred.lowercased()) }
                if parts.count > 1, !parts[0].isEmpty { blocklist.insert(parts[0].lowercased()) }
            }
            persist()
            defaults.removeObject(forKey: "vocabularySuggestions.dismissed")
        }
        migrateIfNeeded()
    }

    private func migrateIfNeeded() {
        guard defaults.integer(forKey: Key.schemaVersion) < LearnedRuleMigration.schemaVersion else {
            return
        }
        let surviving = records.filter {
            LearnedRuleMigration.survivesV2(source: $0.source, heard: $0.heard)
        }
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
