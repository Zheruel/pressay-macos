import Foundation

public enum HoldKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case rightOption = "Right Option"
    case leftOption = "Left Option"

    public var id: String { rawValue }

    public var keyCode: Int64 {
        switch self {
        case .rightOption: 61
        case .leftOption: 58
        }
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case processing
    case succeeded
    case failed(String)
}

public struct DictationStateMachine: Sendable {
    public private(set) var phase: DictationPhase = .idle

    public init() {}

    @discardableResult
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .recording
        return true
    }

    @discardableResult
    public mutating func stop() -> Bool {
        guard phase == .recording else { return false }
        phase = .processing
        return true
    }

    public mutating func cancel() { phase = .idle }

    public mutating func succeed() {
        guard phase == .processing else { return }
        phase = .succeeded
    }

    public mutating func fail(_ message: String) { phase = .failed(message) }
    public mutating func reset() { phase = .idle }
}

public struct AudioClip: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let duration: TimeInterval

    public init(samples: [Float], sampleRate: Int = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
}

public enum DictationProcessingPolicy {
    public static let normalPipelineLimit: TimeInterval = 1.85

    public static func isLongForm(duration: TimeInterval, characterCount: Int) -> Bool {
        duration >= 30 || characterCount >= 500
    }

    public static func asrTimeout(duration: TimeInterval) -> TimeInterval {
        guard duration >= 30 else { return normalPipelineLimit }
        return min(30, max(6, 2 + duration * 0.12))
    }

    public static func polishTimeout(
        duration: TimeInterval,
        characterCount: Int,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        if isLongForm(duration: duration, characterCount: characterCount) {
            return min(20, max(8, duration * 0.12))
        }
        guard elapsed < 1.70 else { return nil }
        return max(0, normalPipelineLimit - elapsed)
    }
}

public struct ASRTranscript: Codable, Sendable {
    public let text: String
    public let processingTime: TimeInterval

    public init(
        text: String,
        processingTime: TimeInterval
    ) {
        self.text = text
        self.processingTime = processingTime
    }
}

public struct DictationContext: Codable, Sendable {
    public let targetBundleID: String?
    public let leadingText: String
    public let trailingText: String
    public let vocabulary: [String]

    public init(
        targetBundleID: String?,
        leadingText: String = "",
        trailingText: String = "",
        vocabulary: [String] = []
    ) {
        self.targetBundleID = targetBundleID
        self.leadingText = String(leadingText.suffix(500))
        self.trailingText = String(trailingText.prefix(500))
        self.vocabulary = vocabulary
    }
}

public struct PolishResult: Codable, Sendable {
    public let text: String
    public let usedLanguageModel: Bool
    public let processingTime: TimeInterval

    public init(
        text: String,
        usedLanguageModel: Bool,
        processingTime: TimeInterval
    ) {
        self.text = text
        self.usedLanguageModel = usedLanguageModel
        self.processingTime = processingTime
    }
}

public enum LocalFlowError: LocalizedError, Sendable {
    case microphoneUnavailable
    case audioConversionFailed
    case recordingTooShort
    case silence
    case modelUnavailable(String)
    case emptyTranscript
    case insertionFailed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .microphoneUnavailable: "No usable microphone is available."
        case .audioConversionFailed: "The microphone audio could not be prepared for transcription."
        case .recordingTooShort: "The hold was too short to contain speech."
        case .silence: "No speech was detected."
        case .modelUnavailable(let detail): "The local model is unavailable: \(detail)"
        case .emptyTranscript: "The model returned an empty transcript."
        case .insertionFailed: "The prompt was copied, but the target field could not be edited."
        case .timedOut: "Local processing exceeded the latency budget."
        }
    }
}
