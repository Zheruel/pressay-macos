import AVFoundation

@MainActor
final class DictationSoundPlayer {
    enum Cue: Hashable {
        case begin
        case release
        case polishRelease
        case learned
        case cancel
        case error

        var duration: TimeInterval {
            switch self {
            case .begin: 0.135
            case .release: 0.135
            case .polishRelease: 0.165
            case .learned: 0.28
            case .cancel: 0.065
            case .error: 0.115
            }
        }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var assetBuffers: [Cue: AVAudioPCMBuffer] = [:]
    // nonisolated(unsafe): written once in init, read once in deinit.
    private nonisolated(unsafe) var configurationObserver: (any NSObjectProtocol)?
    private let synthFormat = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channels: 2
    )!

    var beginCaptureDelay: TimeInterval {
        Cue.begin.duration + min(0.025, engine.outputNode.presentationLatency)
    }

    init() {
        engine.attach(player)
        assetBuffers[.begin] = loadBuffer(named: "dictation-begin")
        assetBuffers[.release] = loadBuffer(named: "dictation-release")
        connectPlayer()
        try? catchingObjCException { try engine.start() }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func play(_ cue: Cue) {
        if !engine.isRunning {
            try? catchingObjCException { try engine.start() }
        }
        // A dead output device skips the earcon; dictation continues.
        guard engine.isRunning else { return }
        // Synthesized cues are deterministic; cache so the ~8k-frame synthesis
        // loop doesn't rerun on the latency-sensitive key-release path.
        if assetBuffers[cue] == nil, let synthesized = makeBuffer(for: cue) {
            assetBuffers[cue] = synthesized
        }
        guard let buffer = assetBuffers[cue] else { return }
        try? catchingObjCException {
            player.stop()
            player.scheduleBuffer(buffer, at: nil)
            player.play()
        }
    }

    /// Player → mixer uses the cue buffer's format so the mixer resamples to
    /// whatever the output device currently negotiates — never the reverse.
    private func connectPlayer() {
        try? catchingObjCException {
            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: assetBuffers[.begin]?.format ?? synthFormat
            )
            engine.prepare()
        }
    }

    /// Rebuilds the graph now but restarts lazily on the next play() —
    /// starting mid-device-transition is exactly when CoreAudio fails.
    private func handleConfigurationChange() {
        try? catchingObjCException {
            player.stop()
            engine.stop()
            engine.disconnectNodeOutput(player)
        }
        connectPlayer()
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
        // Rising sweep, unlike the falling dictation release, so the ear knows
        // a longer cloud polish is starting.
        case .polishRelease: (640, 960, 0.045)
        case .learned: (880, 1320, 0.035)
        case .cancel: (540, 470, 0.036)
        case .error: (430, 330, 0.042)
        }

        let sampleRate = synthFormat.sampleRate
        let frameCount = Int((cue.duration * sampleRate).rounded(.up))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: synthFormat,
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
