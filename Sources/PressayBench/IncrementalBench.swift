import FluidAudio
import Foundation
import PressayCore
import PressayTranscription

/// Transcribe-while-talking simulation over stored dictation audio. Silero marks pauses as the audio
/// "arrives"; once a piece is at least `--min-piece` seconds long, the first pause of `--gap` seconds
/// cuts it and it is transcribed in the background. Only the tail is left when the key is released.
/// Reports the wait after release against transcribing the whole clip, and how the texts differ.
extension Bench {
    struct IncrementalRow: Codable {
        let id: String
        let duration: Double
        let whole: String
        let wholeLatency: Double
        let minPiece: Double
        let pieces: [Double]
        let text: String
        let wait: Double
    }

    static func runIncremental(options: [String: String]) async throws {
        guard let dir = options["audio-dir"], let output = options["output"] else {
            throw BenchError.usage("incremental needs --audio-dir DIR --output out.json [--min-piece 4,8,15] [--gap 0.5] [--min-duration 6]")
        }
        let engine = ASRModel(rawValue: options["engine"] ?? ASRModel.qwen3ASR17.rawValue) ?? .qwen3ASR17
        let minPieces = (options["min-piece"] ?? "4,8,15").split(separator: ",").compactMap { Double($0) }
        let gap = Double(options["gap"] ?? "0.5") ?? 0.5
        let minDuration = Double(options["min-duration"] ?? "6") ?? 6
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".caf") || $0.hasSuffix(".wav") }.sorted()

        let transcriber = GGMLTranscriber(model: engine, language: options["language"] ?? "en")
        try await transcriber.prepare()
        let vad = try await VadManager()
        var rows: [IncrementalRow] = []

        for file in files {
            let samples = try loadSamples("\(dir)/\(file)")
            let duration = Double(samples.count) / 16_000
            guard duration >= minDuration else { continue }
            let id = (file as NSString).deletingPathExtension

            // Silero decision per 256 ms chunk, as the live path would see it.
            var state = await vad.makeStreamState()
            var talking: [Bool] = []
            var speaking = false
            for start in stride(from: 0, to: samples.count, by: VadManager.chunkSize) {
                let chunk = Array(samples[start..<min(start + VadManager.chunkSize, samples.count)])
                let result = try await vad.processStreamingChunk(chunk, state: state)
                state = result.state
                speaking = result.probability >= (speaking ? 0.35 : 0.5)
                talking.append(speaking)
            }

            let wholeStart = ContinuousClock.now
            let whole = (try? await transcriber.transcribe(AudioClip(samples: samples)).text) ?? ""
            let wholeLatency = wholeStart.duration(to: .now).seconds

            for minPiece in minPieces {
                // Cut points in samples: the middle of the first long-enough pause after minPiece seconds.
                var cuts: [Int] = []
                var pieceStart = 0
                var silentRun = 0
                let gapChunks = max(1, Int((gap * 16_000 / Double(VadManager.chunkSize)).rounded(.up)))
                for (index, isSpeech) in talking.enumerated() {
                    silentRun = isSpeech ? 0 : silentRun + 1
                    let end = (index + 1) * VadManager.chunkSize
                    if silentRun >= gapChunks, Double(end - pieceStart) / 16_000 >= minPiece, end < samples.count {
                        let cut = end - silentRun * VadManager.chunkSize / 2
                        cuts.append(cut)
                        pieceStart = cut
                        silentRun = 0
                    }
                }
                let bounds = zip([0] + cuts, cuts + [samples.count]).filter { $0.1 > $0.0 }
                var texts: [String] = []
                var finish = 0.0
                for (lo, hi) in bounds {
                    // The last piece becomes available at release; earlier ones once their pause is heard.
                    let available = Double(hi) / 16_000 + (hi == samples.count ? 0 : gap / 2)
                    let started = ContinuousClock.now
                    let text = (try? await transcriber.transcribe(AudioClip(samples: Array(samples[lo..<hi]))).text) ?? ""
                    finish = max(available, finish) + started.duration(to: .now).seconds
                    texts.append(text)
                }
                rows.append(IncrementalRow(
                    id: id, duration: duration, whole: whole, wholeLatency: wholeLatency, minPiece: minPiece,
                    pieces: bounds.map { Double($0.1 - $0.0) / 16_000 }, text: AudioChunking.join(texts),
                    wait: max(0, finish - duration)
                ))
            }
            print(String(format: "%@ %.1fs whole %.2fs  %@", id, duration, wholeLatency,
                         rows.suffix(minPieces.count).map { String(format: "%g:%d/%.2fs", $0.minPiece, $0.pieces.count, $0.wait) }.joined(separator: " ")))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(fileURLWithPath: output))
    }
}
