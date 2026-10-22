import FluidAudio
import Foundation
import PressayCore
import PressayTranscription

/// `meeting --audio m.wav --engine <ASRModel|parakeet-v2|parakeet-v3|cohere> --max-segment 12 --output out.json`
/// Splits the file with the app's SpeechSegmenter, as a live meeting would, and transcribes each segment.
extension Bench {
    struct MeetingSegment: Codable {
        let start: TimeInterval
        let duration: TimeInterval
        let latency: TimeInterval
        let text: String
    }

    struct MeetingResult: Codable {
        let engine: String
        let segmenter: String
        let maxSegment: TimeInterval
        let audioSeconds: TimeInterval
        let computeSeconds: TimeInterval
        let loadSeconds: TimeInterval
        let segments: [MeetingSegment]
    }

    static func runMeeting(options: [String: String]) async throws {
        guard let audio = options["audio"], let output = options["output"] else {
            throw BenchError.usage("meeting needs --audio file.wav --output out.json [--engine qwen3ASR17] [--max-segment 12] [--cohere-dir dir]")
        }
        let engine = options["engine"] ?? ASRModel.qwen3ASR17.rawValue
        let maxSegment = TimeInterval(options["max-segment"] ?? "12") ?? 12
        let samples = try loadSamples(audio)

        // --segmenter energy (the app's) | floor=<rms> (energy with a lower absolute floor) | silero
        let mode = options["segmenter"] ?? "energy"
        var pieces: [SpeechSegmenter.Segment] = []
        if mode == "silero" {
            let vad = try await VadManager()
            var config = VadSegmentationConfig.default
            config.maxSpeechDuration = maxSegment
            config.minSilenceDuration = 0.5
            config.speechPadding = 0.2
            for range in try await vad.segmentSpeech(samples, config: config) {
                let lo = max(0, range.startSample(sampleRate: 16_000)), hi = min(samples.count, range.endSample(sampleRate: 16_000))
                guard hi > lo else { continue }
                pieces.append(SpeechSegmenter.Segment(start: Double(lo) / 16_000, samples: Array(samples[lo..<hi])))
            }
        } else if mode == "vad-stream" {
            // The app's live path: Silero judges each 256 ms chunk, the segmenter cuts.
            let vad = try await VadManager()
            var state = await vad.makeStreamState()
            var segmenter = SpeechSegmenter()
            segmenter.maximumLength = maxSegment
            var talking = false
            for chunk in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
                let piece = Array(samples[chunk..<min(chunk + VadManager.chunkSize, samples.count)])
                let result = try await vad.processStreamingChunk(piece, state: state)
                state = result.state
                talking = result.probability >= (talking ? 0.35 : 0.5)
                pieces += segmenter.append(piece, speech: talking)
            }
            if let last = segmenter.finish() { pieces.append(last) }
        } else {
            var segmenter = SpeechSegmenter()
            segmenter.maximumLength = maxSegment
            if mode.hasPrefix("floor="), let floor = Float(mode.dropFirst(6)) { segmenter.speechFloor = floor }
            for chunk in stride(from: 0, to: samples.count, by: 1_600) {
                pieces += segmenter.append(Array(samples[chunk..<min(chunk + 1_600, samples.count)]))
            }
            if let last = segmenter.finish() { pieces.append(last) }
        }
        print("\(mode): \(Int(pieces.reduce(0) { $0 + $1.duration }))s of \(samples.count / 16_000)s kept")

        let loadStart = ContinuousClock.now
        let transcribe = try await makeEngine(engine, options: options)
        let loadSeconds = loadStart.duration(to: .now).seconds
        print("\(engine): \(pieces.count) segments, loaded in \(String(format: "%.1f", loadSeconds))s")

        var segments: [MeetingSegment] = []
        let started = ContinuousClock.now
        for piece in pieces {
            let t0 = ContinuousClock.now
            let text = (try? await transcribe(piece.samples)) ?? ""
            segments.append(MeetingSegment(start: piece.start, duration: piece.duration, latency: t0.duration(to: .now).seconds, text: text))
        }
        let compute = started.duration(to: .now).seconds
        let audioSeconds = Double(samples.count) / 16_000
        print(String(format: "  %.0fs audio in %.1fs (%.1fx realtime)", audioSeconds, compute, audioSeconds / compute))
        let result = MeetingResult(engine: engine, segmenter: mode, maxSegment: maxSegment, audioSeconds: audioSeconds,
                                   computeSeconds: compute, loadSeconds: loadSeconds, segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: output))
    }

    private static func makeEngine(_ name: String, options: [String: String]) async throws -> ([Float]) async throws -> String {
        switch name {
        case "parakeet-v2", "parakeet-v3":
            let models = try await AsrModels.downloadAndLoad(version: name == "parakeet-v2" ? .v2 : .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return { samples in
                var state = TdtDecoderState.make()
                return try await manager.transcribe(samples, decoderState: &state).text
            }
        case "cohere":
            guard let dir = options["cohere-dir"] else { throw BenchError.usage("cohere needs --cohere-dir") }
            let url = URL(fileURLWithPath: dir)
            let models = try await CoherePipeline.loadModels(encoderDir: url, decoderDir: url, vocabDir: url)
            let pipeline = CoherePipeline()
            return { samples in
                try await pipeline.transcribe(audio: samples, models: models).text
            }
        default:
            guard let model = ASRModel(rawValue: name) else { throw BenchError.usage("unknown --engine \(name)") }
            let transcriber = SpeechTranscribers.make(model: model, language: "en",
                bundleURL: URL(fileURLWithPath: options["runtime-app"] ?? ".build/Pressay.app"))
            try await transcriber.prepare()
            return { samples in try await transcriber.transcribe(AudioClip(samples: samples)).text }
        }
    }
}
