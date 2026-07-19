@preconcurrency import AVFoundation
import Foundation
import LocalFlowCore

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
    private var configurationObserver: (any NSObjectProtocol)?

    var onLevel: (@Sendable (LevelFrame) -> Void)?
    /// Fired on the main queue when a device change ends the capture early.
    var onCaptureFailed: ((String) -> Void)?

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

    func start() throws {
        guard !isRecording else { return }
        // A stale running engine (swallowed stop, partial teardown) would
        // otherwise diverge from isRecording and silently kill every dictation.
        if engine.isRunning {
            try? catchingObjCException {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw LocalFlowError.microphoneUnavailable
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
            sampleRate = format.sampleRate
        }
        speechMeter.reset()
        lastLevelUpdate = Date()
        onLevel?(.silent)
        do {
            try installTapAndStart(on: input, format: format)
        } catch {
            try? catchingObjCException { input.removeTap(onBus: 0) }
            throw LocalFlowError.microphoneUnavailable
        }
        isRecording = true
    }

    /// Stops capture and hands over the raw samples; resample + trim happen
    /// later, off the main actor.
    func stop() throws -> RawCapture {
        guard isRecording else { throw LocalFlowError.recordingTooShort }
        isRecording = false
        try? catchingObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        return lock.withLock {
            var segments = finishedSegments
            if !samples.isEmpty {
                segments.append(RawCapture.Segment(samples: samples, sampleRate: sampleRate))
            }
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
            return RawCapture(segments: segments)
        }
    }

    func cancel() {
        tearDownCapture()
    }

    /// Seals the samples captured so far as a segment and restarts the tap
    /// with the new device format. Idempotent — macOS can post this
    /// notification several times per device transition.
    private func handleConfigurationChange() {
        guard isRecording else { return }

        let input = engine.inputNode
        try? catchingObjCException { input.removeTap(onBus: 0) }

        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            abortCapture()
            return
        }

        lock.withLock {
            if !samples.isEmpty {
                finishedSegments.append(RawCapture.Segment(samples: samples, sampleRate: sampleRate))
                samples.removeAll(keepingCapacity: true)
            }
            sampleRate = format.sampleRate
        }

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
        tearDownCapture()
        onCaptureFailed?("Microphone changed — try again")
    }

    private func tearDownCapture() {
        isRecording = false
        try? catchingObjCException {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            finishedSegments.removeAll()
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let source = channelData[channel]
            for index in 0..<frameCount {
                mono[index] += source[index] / Float(channelCount)
            }
        }

        lock.withLock { samples.append(contentsOf: mono) }
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
