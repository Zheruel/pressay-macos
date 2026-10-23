@preconcurrency import AVFoundation
import Foundation
import PressayCore
import os

final class AudioRecorder: @unchecked Sendable {
    struct LevelFrame: Sendable {
        let bars: [Float]

        static let silent = LevelFrame(bars: [0, 0, 0, 0])
    }

    /// One segment per hardware format: a Bluetooth headset can flip A2DP → HFP mid-dictation.
    struct RawCapture: Sendable {
        struct Segment: Sendable {
            let samples: [Float]
            let sampleRate: Double
        }

        let segments: [Segment]
        /// Seconds from the first sample; still valid after resampling to 16 kHz.
        let earconWindow: Range<TimeInterval>?

        var duration: TimeInterval {
            segments.reduce(0) { $0 + Double($1.samples.count) / max($1.sampleRate, 1) }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var finishedSegments: [RawCapture.Segment] = []
    private var lastLevelUpdate = Date.distantPast
    private var speechMeter = SpeechActivityMeter()
    private var isRecording = false
    private var engineOpen = false
    private var configurationObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "dev.localflow.app", category: "audio")

    /// Keeps the word onset spoken before `start()` lands.
    private var preRoll: [Float] = []
    private var preRollWrite = 0
    private var preRollFilled = 0

    /// Bluetooth links deliver zero-filled buffers for hundreds of ms while negotiating.
    private var hasLiveAudio = false
    private var announcedFirstAudio = false
    private var openedAt = Date.distantPast
    private var earconWindow: Range<TimeInterval>?

    var onLevel: (@Sendable (LevelFrame) -> Void)?
    /// The only honest moment to tell the user the mic is listening.
    var onFirstAudio: (@Sendable () -> Void)?
    /// Fired on the main queue.
    var onCaptureFailed: ((String) -> Void)?

    /// CoreAudio UID; nil follows the system default.
    var preferredInputUID: String?

    init() {
        // .main serializes with start()/stop()/cancel(), so isRecording needs no lock here.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// For sleep/lock: a half-torn-down Bluetooth link wedges the input into silence on wake.
    func forceClose() {
        closeEngine()
    }

    // MARK: - Dictation

    func start() throws {
        guard !isRecording else { return }
        if !engineOpen {
            try openEngine()
        }

        lastLevelUpdate = Date()
        announcedFirstAudio = false
        lock.withLock {
            earconWindow = nil
            finishedSegments.removeAll()
            samples = drainPreRollLocked()
            isRecording = true
        }

        if hasLiveAudio {
            announcedFirstAudio = true
            onFirstAudio?()
        }
    }

    /// Release the hardware before resampling and transcription run off the main actor.
    func stop() throws -> RawCapture {
        guard isRecording else { throw PressayError.recordingTooShort }
        defer { closeEngine() }

        return lock.withLock {
            isRecording = false
            var segments = finishedSegments
            if !samples.isEmpty {
                segments.append(RawCapture.Segment(samples: samples, sampleRate: sampleRate))
            }
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
            return RawCapture(segments: segments, earconWindow: earconWindow)
        }
    }

    func cancel() {
        closeEngine()
        onLevel?(.silent)
    }

    /// The cue plays into a live mic, so the trimmer must skip it.
    func markEarcon(duration: TimeInterval) {
        guard isRecording else { return }
        // Whole-capture time, not per segment: an HFP flip seals segment 0 and would reset this to 0.
        lock.withLock {
            let elapsed = finishedSegments.reduce(0.0) { $0 + Double($1.samples.count) / max($1.sampleRate, 1) }
                + Double(samples.count) / max(sampleRate, 1)
            earconWindow = elapsed..<(elapsed + duration)
        }
    }

    struct LiveAudio: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let earconWindow: Range<TimeInterval>?
    }

    /// What the dictation has captured from `offset` on, for transcribing while the key is held.
    /// Nil when not recording or once the hardware format changed (the whole clip is transcribed then).
    func liveAudio(from offset: Int) -> LiveAudio? {
        lock.withLock {
            guard isRecording, finishedSegments.isEmpty, offset <= samples.count else { return nil }
            return LiveAudio(samples: Array(samples[offset...]), sampleRate: sampleRate, earconWindow: earconWindow)
        }
    }

    // MARK: - Engine

    private func openEngine() throws {
        // A stale running engine (swallowed stop) would diverge from engineOpen and kill every dictation.
        if engine.isRunning || engineOpen {
            closeEngine()
        }
        let input = engine.inputNode
        applyPreferredInput(to: input)

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw PressayError.microphoneUnavailable
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
            sampleRate = format.sampleRate
            allocatePreRollLocked(sampleRate: format.sampleRate)
        }
        speechMeter.reset()
        hasLiveAudio = false
        lastLevelUpdate = Date()

        let startedAt = Date()
        do {
            try installTapAndStart(on: input, format: format)
        } catch {
            closeEngine()
            throw PressayError.microphoneUnavailable
        }
        engineOpen = true
        openedAt = Date()
        logger.info(
            """
            mic opened: \(format.sampleRate, privacy: .public) Hz \
            \(format.channelCount, privacy: .public) ch, \
            engine.start() took \(Date().timeIntervalSince(startedAt) * 1000, privacy: .public) ms
            """
        )
    }

    private func closeEngine() {
        if engineOpen {
            logger.info("mic closed after \(Date().timeIntervalSince(self.openedAt), privacy: .public)s")
        }
        engineOpen = false
        hasLiveAudio = false
        // Remove the tap first: afterwards no render-thread callback can be in flight.
        try? catchingObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            isRecording = false
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
            preRoll.removeAll(keepingCapacity: true)
            preRollWrite = 0
            preRollFilled = 0
        }
    }

    private func applyPreferredInput(to input: AVAudioInputNode) {
        guard let preferredInputUID,
              let device = AudioDeviceMonitor.device(forUID: preferredInputUID)
        else { return }
        do {
            try input.auAudioUnit.setDeviceID(device.id)
        } catch {
            logger.error("could not pin input to \(device.name, privacy: .public): \(error)")
        }
    }

    /// Idempotent: macOS can post this several times per device transition.
    private func handleConfigurationChange() {
        guard engineOpen else { return }
        logger.info("microphone configuration changed")
        // Do not reopen a stream after a recording has ended.
        guard isRecording else {
            closeEngine()
            return
        }

        let input = engine.inputNode
        try? catchingObjCException { input.removeTap(onBus: 0) }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            abortCapture()
            return
        }

        lock.withLock {
            if isRecording, !samples.isEmpty {
                finishedSegments.append(RawCapture.Segment(samples: samples, sampleRate: sampleRate))
                samples.removeAll(keepingCapacity: true)
            }
            sampleRate = format.sampleRate
            allocatePreRollLocked(sampleRate: format.sampleRate)
        }
        // The new device has its own noise floor and may send digital silence while it settles.
        speechMeter.reset()
        hasLiveAudio = false

        do {
            try installTapAndStart(on: input, format: format)
        } catch {
            abortCapture()
        }
    }

    private func installTapAndStart(on input: AVAudioInputNode, format: AVAudioFormat) throws {
        try catchingObjCException {
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            engine.prepare()
            try engine.start()
        }
    }

    private func abortCapture() {
        let wasRecording = isRecording
        closeEngine()
        if wasRecording {
            onCaptureFailed?("Microphone changed — try again")
        }
    }

    // MARK: - Pre-roll

    private func allocatePreRollLocked(sampleRate: Double) {
        let capacity = max(1, Int(sampleRate * DictationProcessingPolicy.preRollDuration))
        preRoll = [Float](repeating: 0, count: capacity)
        preRollWrite = 0
        preRollFilled = 0
    }

    private func appendPreRollLocked(_ mono: [Float]) {
        guard !preRoll.isEmpty else { return }
        let capacity = preRoll.count
        let source = mono.count > capacity ? Array(mono.suffix(capacity)) : mono
        for sample in source {
            preRoll[preRollWrite] = sample
            preRollWrite = (preRollWrite + 1) % capacity
        }
        preRollFilled = min(capacity, preRollFilled + source.count)
    }

    private func drainPreRollLocked() -> [Float] {
        guard preRollFilled > 0, !preRoll.isEmpty else { return [] }
        let capacity = preRoll.count
        let start = (preRollWrite - preRollFilled + capacity) % capacity
        var output = [Float]()
        output.reserveCapacity(preRollFilled)
        for offset in 0..<preRollFilled {
            output.append(preRoll[(start + offset) % capacity])
        }
        preRollWrite = 0
        preRollFilled = 0
        return output
    }

    // MARK: - Capture

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        var peak: Float = 0
        for channel in 0..<channelCount {
            let source = channelData[channel]
            for index in 0..<frameCount {
                mono[index] += source[index] / Float(channelCount)
            }
        }
        for value in mono { peak = max(peak, abs(value)) }

        // Digital silence means the link is negotiating; a live mic always has a noise floor.
        if !hasLiveAudio, peak > 1e-6 {
            hasLiveAudio = true
            logger.info(
                "first live audio \(Date().timeIntervalSince(self.openedAt) * 1000, privacy: .public) ms after open"
            )
        }

        // isRecording is read and flipped under the lock so no buffer lands in the ring after start() drained it.
        let recording = lock.withLock { () -> Bool in
            guard isRecording else {
                appendPreRollLocked(mono)
                return false
            }
            samples.append(contentsOf: mono)
            return true
        }

        if recording, hasLiveAudio, !announcedFirstAudio {
            announcedFirstAudio = true
            onFirstAudio?()
        }
        guard recording else { return }

        let now = Date()
        let levelFrameDuration = now.timeIntervalSince(lastLevelUpdate)
        if levelFrameDuration >= 1.0 / 30.0 {
            lastLevelUpdate = now
            let rms = sqrt(mono.reduce(Float.zero) { $0 + $1 * $1 } / Float(frameCount))
            let activity = speechMeter.process(
                rms: rms,
                frameDuration: min(levelFrameDuration, 0.1)
            )
            guard activity.isSpeech, activity.level > 0 else {
                onLevel?(.silent)
                return
            }

            let segmentSize = max(1, frameCount / 4)
            let bars = (0..<4).map { segment -> Float in
                let start = segment * segmentSize
                let end = segment == 3 ? frameCount : min(frameCount, start + segmentSize)
                guard start < end else { return activity.level }
                let segmentRMS = sqrt(
                    mono[start..<end].reduce(Float.zero) { $0 + $1 * $1 }
                        / Float(end - start)
                )
                let relativeEnergy = min(1.25, max(0.55, segmentRMS / max(rms, 0.000_001)))
                return min(1, activity.level * (0.72 + 0.28 * relativeEnergy))
            }
            onLevel?(LevelFrame(bars: bars))
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
