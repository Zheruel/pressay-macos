@preconcurrency import AVFoundation
import Foundation
import PressayCore
import os

final class AudioRecorder: @unchecked Sendable {
    struct LevelFrame: Sendable {
        let bars: [Float]

        static let silent = LevelFrame(bars: [0, 0, 0, 0])
    }

    /// Raw microphone capture, one segment per hardware format: a Bluetooth
    /// headset flips A2DP → HFP mid-dictation, changing the sample rate.
    struct RawCapture: Sendable {
        struct Segment: Sendable {
            let samples: [Float]
            let sampleRate: Double
        }

        let segments: [Segment]
        /// Where the start cue sits on the capture timeline, measured from the
        /// first sample. Resampling preserves duration, so this stays valid
        /// after conversion to 16 kHz.
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
    /// Tap installed and engine running — true while merely warm, too.
    private var engineOpen = false
    private var configurationObserver: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "dev.localflow.app", category: "audio")

    /// Rolling pre-roll, so pressing the key and speaking in the same motion
    /// keeps the word onset that would otherwise land before `start()`.
    private var preRoll: [Float] = []
    private var preRollWrite = 0
    private var preRollFilled = 0

    /// Whether the device has delivered anything but digital silence. Bluetooth
    /// links hand out zero-filled buffers for hundreds of ms while negotiating.
    private var hasLiveAudio = false
    private var announcedFirstAudio = false
    private var openedAt = Date.distantPast
    private var earconWindow: Range<TimeInterval>?

    var onLevel: (@Sendable (LevelFrame) -> Void)?
    /// Fired once per dictation when real samples start arriving. This is the
    /// only honest moment to tell the user the mic is listening.
    var onFirstAudio: (@Sendable () -> Void)?
    /// Fired on the main queue when a device change ends the capture early.
    var onCaptureFailed: ((String) -> Void)?

    /// CoreAudio UID of the input to pin, or nil to follow the system default.
    var preferredInputUID: String?

    var isWarm: Bool { engineOpen }

    init() {
        // queue: .main serializes the handler with start()/stop()/cancel(),
        // which only run on the main actor, so isRecording needs no lock.
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

    // MARK: - Warmth

    /// Opens the stream without starting a dictation, so the next key press
    /// pays no hardware start latency.
    func warmUp() throws {
        guard !engineOpen else { return }
        try openEngine()
    }

    /// Closes the stream. Safe to call while idle; refuses to cut a dictation.
    func coolDown() {
        guard !isRecording else { return }
        closeEngine()
    }

    // MARK: - Dictation

    func start() throws {
        guard !isRecording else { return }
        if !engineOpen {
            try openEngine()
        }

        // A warm mic keeps its converged noise floor; a freshly opened one has
        // nothing to preserve and was reset in openEngine().
        lastLevelUpdate = Date()
        announcedFirstAudio = false
        earconWindow = nil
        lock.withLock {
            finishedSegments.removeAll()
            samples = drainPreRollLocked()
            isRecording = true
        }

        // Already-flowing audio means the cue can fire now rather than waiting
        // for the next buffer.
        if hasLiveAudio {
            announcedFirstAudio = true
            onFirstAudio?()
        }
    }

    /// Stops the dictation and hands over the raw samples; resample + trim
    /// happen later, off the main actor. The stream stays open — the warm
    /// window decides when it closes.
    func stop() throws -> RawCapture {
        guard isRecording else { throw PressayError.recordingTooShort }

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
        lock.withLock {
            isRecording = false
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
        }
        onLevel?(.silent)
    }

    /// Records where the start cue lands on the capture timeline. The cue now
    /// plays into a live mic, so the trimmer needs to know to skip it.
    func markEarcon(duration: TimeInterval) {
        guard isRecording else { return }
        let elapsed = lock.withLock { Double(samples.count) / max(sampleRate, 1) }
        earconWindow = elapsed..<(elapsed + duration)
    }

    // MARK: - Engine

    private func openEngine() throws {
        // A stale running engine (swallowed stop, partial teardown) would
        // otherwise diverge from engineOpen and silently kill every dictation.
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
            try? catchingObjCException { input.removeTap(onBus: 0) }
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
        // Stop the tap before touching shared state: once it is removed no
        // further render-thread callback can be in flight.
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
            // Fall back to the system default rather than refusing to record.
            logger.error("could not pin input to \(device.name, privacy: .public): \(error)")
        }
    }

    /// Seals the samples captured so far as a segment and restarts the tap
    /// with the new device format. Idempotent — macOS can post this
    /// notification several times per device transition.
    private func handleConfigurationChange() {
        guard engineOpen else { return }
        logger.info("configuration change while \(self.isRecording ? "recording" : "warm", privacy: .public)")

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
        // The new device has its own noise floor and may hand out digital
        // silence again while it settles.
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
        // A buffer longer than the ring can only contribute its tail.
        let source = mono.count > capacity ? Array(mono.suffix(capacity)) : mono
        for sample in source {
            preRoll[preRollWrite] = sample
            preRollWrite = (preRollWrite + 1) % capacity
        }
        preRollFilled = min(capacity, preRollFilled + source.count)
    }

    /// Oldest-first copy of the ring, then reset so the next dictation starts clean.
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

        // Digital silence means the link is still negotiating, not that the
        // room is quiet: a live mic always carries a noise floor.
        if !hasLiveAudio, peak > 1e-6 {
            hasLiveAudio = true
            logger.info(
                "first live audio \(Date().timeIntervalSince(self.openedAt) * 1000, privacy: .public) ms after open"
            )
        }

        // Reading isRecording inside the lock, and flipping it inside the lock
        // in start()/stop(), is what stops a buffer landing in the pre-roll ring
        // microseconds after start() drained it — which would silently drop the
        // very word onset this class exists to preserve.
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
