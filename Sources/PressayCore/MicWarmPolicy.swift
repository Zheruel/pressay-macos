import Foundation

/// Decides whether the microphone stream stays open between dictations.
///
/// Opening a cold stream costs ~110 ms on the built-in mic and 550–670 ms on a
/// Bluetooth headset, all of it spent after the key is already down. Worse,
/// cycling a Bluetooth input open and closed repeatedly can leave it delivering
/// digital silence, which reads as a mysteriously bad transcript rather than an
/// error. Holding the stream open removes both.
///
/// The cost is that macOS drops a Bluetooth headset into its 24 kHz mono call
/// profile for as long as any input stream is open, so the window is skipped
/// while the user is actually listening to something on that device.
///
/// Pure logic, driven by an injected clock so it can be tested without sleeping.
public enum MicWarmPolicy {
    public struct Conditions: Sendable, Equatable {
        /// The user-facing "keep microphone ready" preference.
        public let enabled: Bool
        /// Whether the dictation input is a Bluetooth transport.
        public let isBluetooth: Bool
        /// Whether anything is playing on the default output device.
        public let outputDeviceInUse: Bool
        /// When the last dictation finished; nil before the first one.
        public let lastDictationEnded: Date?

        public init(
            enabled: Bool,
            isBluetooth: Bool,
            outputDeviceInUse: Bool,
            lastDictationEnded: Date?
        ) {
            self.enabled = enabled
            self.isBluetooth = isBluetooth
            self.outputDeviceInUse = outputDeviceInUse
            self.lastDictationEnded = lastDictationEnded
        }
    }

    public static func shouldStayWarm(
        _ conditions: Conditions,
        now: Date,
        window: TimeInterval = DictationProcessingPolicy.micWarmWindow
    ) -> Bool {
        guard conditions.enabled else { return false }
        // Never warm from a cold start: only an actual dictation is evidence
        // that another one is likely, and opening the mic unprompted would light
        // the recording indicator for a user who never asked for it.
        guard let lastDictationEnded = conditions.lastDictationEnded else { return false }
        // Holding a headset in call mode while the user is listening to
        // something costs more than the cold start it would save.
        if conditions.isBluetooth, conditions.outputDeviceInUse { return false }
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
