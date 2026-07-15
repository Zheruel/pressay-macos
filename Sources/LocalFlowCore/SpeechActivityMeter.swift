import Foundation

public struct SpeechActivitySample: Equatable, Sendable {
    public let level: Float
    public let isSpeech: Bool

    public init(level: Float, isSpeech: Bool) {
        self.level = level
        self.isSpeech = isSpeech
    }
}

public struct SpeechActivityMeter: Sendable {
    private var noiseFloorDB: Float = -58
    private var speechActive = false
    private var attackDuration: TimeInterval = 0
    private var quietDuration: TimeInterval = 0
    private var smoothedLevel: Float = 0

    public init() {}

    public mutating func reset() {
        noiseFloorDB = -58
        speechActive = false
        attackDuration = 0
        quietDuration = 0
        smoothedLevel = 0
    }

    public mutating func process(
        rms: Float,
        frameDuration: TimeInterval
    ) -> SpeechActivitySample {
        let decibels = 20 * log10(max(rms, 0.000_001))
        let attackThreshold = max(-43, noiseFloorDB + 10)
        let releaseThreshold = max(-49, noiseFloorDB + 6)

        if !speechActive, decibels < attackThreshold {
            noiseFloorDB += (decibels - noiseFloorDB) * 0.045
        }

        if speechActive {
            if decibels < releaseThreshold {
                quietDuration += frameDuration
                if quietDuration >= 0.20 {
                    speechActive = false
                    attackDuration = 0
                }
            } else {
                quietDuration = 0
            }
        } else if decibels >= attackThreshold {
            attackDuration += frameDuration
            if attackDuration >= 0.04 {
                speechActive = true
                quietDuration = 0
            }
        } else {
            attackDuration = 0
        }

        let rawLevel: Float
        if speechActive {
            let upperSpeechDB: Float = -16
            rawLevel = min(1, max(0, (decibels - releaseThreshold) / (upperSpeechDB - releaseThreshold)))
        } else {
            rawLevel = 0
        }

        let smoothing: Float = rawLevel > smoothedLevel ? 0.52 : 0.22
        smoothedLevel += (rawLevel - smoothedLevel) * smoothing
        if !speechActive, smoothedLevel < 0.025 {
            smoothedLevel = 0
        }

        return SpeechActivitySample(
            level: speechActive ? smoothedLevel : 0,
            isSpeech: speechActive
        )
    }
}
