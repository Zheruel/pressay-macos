import Foundation

/// One-time cleanups of persisted learned rules when the matcher changes.
public enum LearnedRuleMigration {
    /// Version 1: the deterministic matcher gained gates (minimum key length,
    /// distance-scaled evidence) after v0 stores accumulated false positives
    /// like "mix → macOS". Det rules are dropped wholesale — the daily pass
    /// rebuilds them from the 30-day history under the fixed matcher — while
    /// k3 rules, the blocklist, and seen candidates are untouched.
    public static let schemaVersion = 1

    public static func survivesV1(source: String) -> Bool {
        source != LearnedRule.Source.det.rawValue
    }
}

/// Usage-based lifetime for learned rules. A learned word is part of the
/// user's current vocabulary and stays as long as it keeps appearing in
/// transcripts; only genuinely abandoned words age out. Deliberately much
/// longer than the 30-day transcript window — history retention is a privacy
/// setting, not a vocabulary one.
public enum LearnedRuleRetention {
    public static let unusedLifetime: TimeInterval = 90 * 24 * 3_600

    public static func isExpired(lastSeen: Date, now: Date = .now) -> Bool {
        now.timeIntervalSince(lastSeen) > unusedLifetime
    }
}
