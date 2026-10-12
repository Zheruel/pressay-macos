import Foundation

/// Utterance splitter. Speech is either judged by energy against an adaptive noise floor, so steady hum
/// never counts, or decided by the caller (a voice-activity model) per batch of samples.
public struct SpeechSegmenter: Sendable {
    public struct Segment: Equatable, Sendable {
        /// Seconds from the start of the stream.
        public let start: TimeInterval
        public let samples: [Float]
        public var duration: TimeInterval { Double(samples.count) / 16_000 }

        public init(start: TimeInterval, samples: [Float]) {
            self.start = start
            self.samples = samples
        }
    }

    public var pauseLength: TimeInterval = 0.7
    public var maximumLength: TimeInterval = 20
    public var minimumSpeech: TimeInterval = 0.4
    /// Frames quieter than this never count as speech, whatever the noise floor.
    public var speechFloor: Float = 0.006

    private static let frame = 480 // 30 ms
    private var pending: [Float] = []
    private var current: [Float] = []
    private var currentStart: Int = 0
    private var consumed: Int = 0
    private var speechFrames = 0
    private var silentRun = 0
    private var noiseFloor: Float = 0.002

    public init() {}

    /// `speech` overrides the energy check for these samples when a model has judged them.
    public mutating func append(_ samples: [Float], speech: Bool? = nil) -> [Segment] {
        pending += samples
        var finished: [Segment] = []
        while pending.count >= Self.frame {
            let frame = Array(pending.prefix(Self.frame))
            pending.removeFirst(Self.frame)
            if let segment = process(frame, speech: speech) { finished.append(segment) }
        }
        return finished
    }

    public mutating func finish() -> Segment? {
        if !pending.isEmpty {
            current += pending
            pending = []
        }
        return cut()
    }

    private mutating func process(_ frame: [Float], speech: Bool?) -> Segment? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let isSpeech = speech ?? (rms > max(noiseFloor * 3, speechFloor))
        if !isSpeech {
            // Track the floor only on quiet frames; slow rise, fast fall.
            noiseFloor = rms < noiseFloor ? rms * 0.5 + noiseFloor * 0.5 : noiseFloor * 0.995 + rms * 0.005
        }
        let framesPerSecond = 16_000.0 / Double(Self.frame)

        if current.isEmpty && !isSpeech {
            // Keep 300 ms of lead-in so the first syllable isn't clipped.
            consumed += frame.count
            leadIn = Array((leadIn + frame).suffix(Self.frame * 10))
            return nil
        }
        if current.isEmpty {
            currentStart = consumed - leadIn.count
            current = leadIn
            leadIn = []
        }
        current += frame
        consumed += frame.count
        if isSpeech {
            speechFrames += 1
            silentRun = 0
        } else {
            silentRun += 1
        }
        let length = Double(current.count) / 16_000
        if Double(silentRun) / framesPerSecond >= pauseLength || length >= maximumLength {
            return cut()
        }
        return nil
    }

    private var leadIn: [Float] = []

    private mutating func cut() -> Segment? {
        defer {
            current = []
            speechFrames = 0
            silentRun = 0
        }
        let speech = Double(speechFrames) * Double(Self.frame) / 16_000
        guard speech >= minimumSpeech else { return nil }
        let tail = max(0, silentRun - 5) * Self.frame
        let samples = Array(current.dropLast(min(tail, current.count)))
        return Segment(start: Double(currentStart) / 16_000, samples: samples)
    }
}
