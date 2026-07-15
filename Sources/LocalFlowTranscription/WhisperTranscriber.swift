import Foundation
import LocalFlowCore
import WhisperKit

/// The single calibrated transcription path: English Whisper Large V3 Turbo
/// with strict greedy decoding and silence-aware chunking for long dictations.
public actor WhisperTranscriber {
    public static let modelName = "Whisper Large V3 Turbo"

    private static let model = "large-v3-v20240930_turbo_632MB"
    private var kit: WhisperKit?

    public init() {}

    public func prepare() async throws {
        guard kit == nil else { return }
        let modelDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LocalFlow/Models/WhisperKit", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        kit = try await WhisperKit(
            model: Self.model,
            downloadBase: modelDirectory,
            verbose: false,
            prewarm: true,
            load: true,
            download: true
        )
    }

    public func transcribe(_ clip: AudioClip) async throws -> ASRTranscript {
        try await prepare()
        guard let kit else { throw LocalFlowError.modelUnavailable(Self.modelName) }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureFallbackCount: 0,
            topK: 5,
            usePrefillPrompt: true,
            detectLanguage: false,
            withoutTimestamps: true,
            wordTimestamps: false,
            compressionRatioThreshold: nil,
            // LocalFlow already rejects silence and conservatively trims audio.
            logProbThreshold: nil,
            noSpeechThreshold: nil,
            concurrentWorkerCount: 1,
            chunkingStrategy: ChunkingStrategy.vad
        )

        let started = ContinuousClock.now
        let results = await kit.transcribe(audioArrays: [clip.samples], decodeOptions: options)
        guard let segments = results.first ?? nil, !segments.isEmpty else {
            throw LocalFlowError.emptyTranscript
        }
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalFlowError.emptyTranscript }

        return ASRTranscript(
            text: text,
            processingTime: started.duration(to: .now).seconds
        )
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
