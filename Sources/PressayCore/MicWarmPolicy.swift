import Foundation

/// Keeps the mic open between dictations. A cold open costs ~110 ms on a built-in mic.
/// Never for Bluetooth: any open input switches the headset to its 24 kHz mono call profile,
/// which cuts and degrades whatever is playing, so a headset mic is open only while the key is held.
public enum MicWarmPolicy {
    public struct Conditions: Sendable, Equatable {
        public let enabled: Bool
        public let isBluetooth: Bool
        /// Nil before the first dictation.
        public let lastDictationEnded: Date?

        public init(enabled: Bool, isBluetooth: Bool, lastDictationEnded: Date?) {
            self.enabled = enabled
            self.isBluetooth = isBluetooth
            self.lastDictationEnded = lastDictationEnded
        }
    }

    public static func shouldStayWarm(
        _ conditions: Conditions,
        now: Date,
        window: TimeInterval = DictationProcessingPolicy.micWarmWindow
    ) -> Bool {
        guard conditions.enabled, !conditions.isBluetooth else { return false }
        // Never warm from a cold start: only an actual dictation is evidence
        // that another one is likely, and opening the mic unprompted would light
        // the recording indicator for a user who never asked for it.
        guard let lastDictationEnded = conditions.lastDictationEnded else { return false }
        let elapsed = now.timeIntervalSince(lastDictationEnded)
        guard elapsed >= 0 else { return true }
        return elapsed < window
    }

    /// When the warm window lapses, or nil if it should not be warm at all.
    public static func expiry(
        _ conditions: Conditions,
        now: Date,
        window: TimeInterval = DictationProcessingPolicy.micWarmWindow
    ) -> Date? {
        guard shouldStayWarm(conditions, now: now, window: window),
              let lastDictationEnded = conditions.lastDictationEnded
        else { return nil }
        return lastDictationEnded.addingTimeInterval(window)
    }
}
