import Foundation

public enum LearnedRuleMigration {
    /// v1: drop det rules (pre-gate false positives like "mix → macOS"); the daily pass rebuilds them.
    /// v2: rebuild det rules for spelling agreement; drop k3 rules with a function word on an edge.
    public static let schemaVersion = 2

    public static func survivesV1(source: String) -> Bool {
        source != LearnedRule.Source.det.rawValue
    }

    public static func survivesV2(source: String, heard: String) -> Bool {
        survivesV1(source: source) && !VocabularyTuner.hasFunctionWordEdge(heard)
    }
}

/// Learned words live while they keep appearing. Deliberately longer than the 30-day transcript
/// window: history retention is a privacy setting, not a vocabulary one.
public enum LearnedRuleRetention {
    public static let unusedLifetime: TimeInterval = 90 * 24 * 3_600

    public static func isExpired(lastSeen: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(lastSeen) > unusedLifetime
    }
}
