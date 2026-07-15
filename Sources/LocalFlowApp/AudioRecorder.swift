@preconcurrency import AVFoundation
import Foundation
import LocalFlowCore

final class AudioRecorder: @unchecked Sendable {
    struct LevelFrame: Sendable {
        let bars: [Float]

        static let silent = LevelFrame(bars: [0, 0, 0, 0])
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000
    private var lastLevelUpdate = Date.distantPast
    private var speechMeter = SpeechActivityMeter()

    var onLevel: (@Sendable (LevelFrame) -> Void)?

    func start() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw LocalFlowError.microphoneUnavailable
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            sampleRate = format.sampleRate
        }
        speechMeter.reset()
        lastLevelUpdate = Date()
        onLevel?(.silent)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() throws -> AudioClip {
        guard engine.isRunning else { throw LocalFlowError.recordingTooShort }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let captured: ([Float], Double) = lock.withLock { (samples, sampleRate) }
        let converted = try AudioResampler.convert(captured.0, from: captured.1)
        let trimmed = try AudioTrimmer.trim(converted)
        return AudioClip(samples: trimmed)
    }

    func cancel() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock { samples.removeAll(keepingCapacity: true) }
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
