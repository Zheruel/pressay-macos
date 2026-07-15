import AVFoundation

@MainActor
final class DictationSoundPlayer {
    enum Cue: Hashable {
        case begin
        case release
        case cancel
        case error

        var duration: TimeInterval {
            switch self {
            case .begin: 0.135
            case .release: 0.135
            case .cancel: 0.065
            case .error: 0.115
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var assetBuffers: [Cue: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
    )!

    var beginCaptureDelay: TimeInterval {
        Cue.begin.duration + min(0.025, engine.outputNode.presentationLatency)
    }

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
        assetBuffers[.begin] = loadBuffer(named: "dictation-begin")
        assetBuffers[.release] = loadBuffer(named: "dictation-release")
    }

    func play(_ cue: Cue) {
        if !engine.isRunning {
            try? engine.start()
        }

        player.stop()
        guard let buffer = assetBuffers[cue] ?? makeBuffer(for: cue) else { return }
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    private func loadBuffer(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "wav",
            subdirectory: "Sounds"
        ), let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            return nil
        }
        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    private func makeBuffer(for cue: Cue) -> AVAudioPCMBuffer? {
        let specification: (startFrequency: Double, endFrequency: Double, gain: Double) = switch cue {
        case .begin: (720, 890, 0.055)
        case .release: (790, 640, 0.045)
        case .cancel: (540, 470, 0.036)
        case .error: (430, 330, 0.042)
        }

        let sampleRate = format.sampleRate
        let frameCount = Int((cue.duration * sampleRate).rounded(.up))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        var phase = 0.0
        var noiseState: UInt32 = 0xA341_316C

        for frame in 0..<frameCount {
            let progress = Double(frame) / Double(max(1, frameCount - 1))
            let shapedProgress = progress * progress * (3 - 2 * progress)
            let frequency = specification.startFrequency
                * pow(specification.endFrequency / specification.startFrequency, shapedProgress)
            phase += 2 * .pi * frequency / sampleRate

            let attack = pow(sin(min(1, progress / 0.075) * .pi / 2), 2)
            let release = pow(sin(min(1, (1 - progress) / 0.24) * .pi / 2), 2)
            let decay = exp(-progress * 1.7)
            let envelope = attack * release * decay

            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
            let transient = noise * exp(-progress * 72) * 0.055
            let body = sin(phase * 0.5) * 0.08
                + sin(phase) * 0.73
                + sin(phase * 2.01 + 0.18) * 0.14
                + sin(phase * 3.98 + 0.42) * 0.035
            let sample = (body * envelope + transient) * specification.gain
            let stereoAir = sin(phase * 2.015 + 0.27) * envelope * specification.gain * 0.012

            channels[0][frame] = Float(sample - stereoAir)
            channels[1][frame] = Float(sample + stereoAir)
        }
        return buffer
    }
}
