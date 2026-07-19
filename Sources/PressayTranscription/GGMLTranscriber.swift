import Foundation
import PressayCore
import TranscribeCpp

/// Dictation on the transcribe.cpp ggml/Metal engine (Whisper GGUF or
/// Parakeet). Validated against the WhisperKit path on the full dictation
/// corpus: identical-or-better transcripts at a fraction of the latency.
public actor GGMLTranscriber: SpeechTranscriber {
    private let asrModel: ASRModel
    private var language: String
    private var session: Session?
    private var preparation: Task<Void, Error>?
    private var statusHandler: (@Sendable (String) -> Void)?

    public init(model: ASRModel, language: String = "en") {
        self.asrModel = model
        self.language = language
    }

    public var engineName: String { asrModel.displayName }

    public func setLanguage(_ language: String) {
        self.language = language
    }

    public func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) {
        statusHandler = handler
    }

    public func prepare() async throws {
        guard session == nil else { return }
        // The actor suspends across download/load; a concurrent prepare()
        // must join the same task instead of starting a second download.
        if let preparation {
            return try await preparation.value
        }
        let task = Task { try await load() }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }

    private func load() async throws {
        guard let download = asrModel.ggufDownload else {
            throw PressayError.modelUnavailable("\(asrModel.displayName) has no GGUF artifact")
        }
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pressay/Models/GGUF", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: download.fileName)

        if !FileManager.default.fileExists(atPath: destination.path) {
            statusHandler?("Downloading \(asrModel.displayName)…")
            let (temporary, response) = try await URLSession.shared.download(from: download.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw PressayError.modelUnavailable("Model download failed for \(asrModel.displayName)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        statusHandler?("Loading \(asrModel.displayName)…")
        let model: Model
        let fresh: Session
        do {
            model = try Model(path: destination.path)
            fresh = try model.session()
        } catch {
            // A cached artifact that fails to load is corrupt (truncated
            // download, disk-full move); drop it so the next prepare()
            // re-downloads instead of failing forever.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Warm the Metal pipelines with a second of silence so the first real
        // dictation doesn't pay shader-compilation cost against its latency
        // budget (mirrors WhisperKit's prewarm).
        nonisolated(unsafe) let warmupSession = fresh
        _ = try? await warmupSession.run([Float](repeating: 0, count: 16_000))
        session = fresh
    }

    public func transcribe(_ clip: AudioClip) async throws -> ASRTranscript {
        try await prepare()
        guard let session else {
            throw PressayError.modelUnavailable("\(asrModel.displayName) is not loaded")
        }
        // Safe to send across the await: the model's run lock serializes all
        // runs, and this actor is the session's only owner (same contract the
        // wrapper's own async overload relies on).
        nonisolated(unsafe) let activeSession = session
        let started = ContinuousClock.now
        var options = RunOptions()
        options.timestamps = .none
        if asrModel.supportsLanguageHint, language != "auto" {
            options.language = language
        }
        // The async overload hops the blocking run off this actor; the model's
        // internal run lock serializes reentrant calls, and Task cancellation
        // (our Timeout wrapper) bridges to the native abort.
        let transcript = try await activeSession.run(clip.samples, options: options)
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PressayError.emptyTranscript }
        return ASRTranscript(
            text: text,
            processingTime: started.duration(to: .now).seconds
        )
    }
}
