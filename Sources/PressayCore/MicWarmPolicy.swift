import Foundation

/// Keeps the mic open between dictations. A cold open costs ~110 ms built-in / 550–670 ms Bluetooth
/// after key-down, and cycling a Bluetooth input can leave it delivering digital silence.
/// Skipped while that headset is playing audio: any open input forces its 24 kHz mono call profile.
public enum MicWarmPolicy {
    public struct Conditions: Sendable, Equatable {
        public let enabled: Bool
        public let isBluetooth: Bool
        /// Whether anything is playing on the default output device.
        public let outputDeviceInUse: Bool
        /// Nil before the first dictation.
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
