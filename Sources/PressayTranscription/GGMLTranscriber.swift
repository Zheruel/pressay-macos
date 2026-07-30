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
    private var progressHandler: (@Sendable (Double?) -> Void)?
    /// Runtime formatting toggles the loaded model actually exposes. Fun-ASR
    /// ships punctuation and ITN off and emits verbatim lowercase otherwise.
    private var supportsPnc = false
    private var supportsItn = false
    /// Longest single run this session accepts, in samples; nil when the
    /// family chunks internally or is otherwise unbounded (Whisper).
    private var maxRunSamples: Int?

    /// How many times a segment may be halved before we give up. Three levels
    /// turns a 100-second clip into ~12-second pieces, far below any context
    /// window here, so exceeding it means something other than length.
    private static let maxSplitDepth = 3
    /// Never split below this: a sub-second fragment carries no usable context
    /// and splitting further cannot help.
    private static let minimumSplitSeconds: TimeInterval = 1.0
    /// The engines all take 16 kHz mono; the recorder resamples to it.
    private static let sampleRate = 16_000

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

    public func setProgressHandler(_ handler: @escaping @Sendable (Double?) -> Void) {
        progressHandler = handler
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
            progressHandler?(nil)
            try await downloadModel(from: download.url, to: destination)
            progressHandler?(nil)
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

        if asrModel.requestsExplicitFormatting {
            supportsPnc = model.supports(.pnc)
            supportsItn = model.supports(.itn)
        }
        // The GGUF is the authority on what it can decode. If the static table
        // in ASRModel ever drifts from the artifact, fall back to the model's
        // own default rather than sending a hint the engine will reject.
        let advertised = model.capabilities.languages
        if language != "auto", !advertised.isEmpty, !advertised.contains(language) {
            language = asrModel.defaultLanguage.whisperCode
        }
        // 0 means "no practical limit" — the family chunks internally.
        let maxAudioMs = fresh.limits.effectiveMaxAudioMs
        maxRunSamples = maxAudioMs > 0
            ? Int(Double(maxAudioMs) / 1000 * Double(Self.sampleRate))
            : nil

        session = fresh
        removeUnusedModelArtifacts(in: directory, keeping: destination)
    }

    /// Deletes GGUFs in the model directory that back no current `ASRModel` —
    /// artifacts left behind by models retired in an update. Files backing a
    /// model that still ships are kept, so switching back never re-downloads.
    private func removeUnusedModelArtifacts(in directory: URL, keeping active: URL) {
        let known = Set(ASRModel.allCases.compactMap { $0.ggufDownload?.fileName })
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for url in contents ?? [] where url.pathExtension == "gguf" {
            guard url != active, !known.contains(url.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Streams the GGUF to `destination`, reporting fractional progress through
    /// `progressHandler`. Uses a download delegate (rather than the plain
    /// `URLSession.download`) so the large Voxtral artifact shows a live bar.
    private func downloadModel(from url: URL, to destination: URL) async throws {
        // `progressHandler` is @Sendable, so the delegate (which fires on the
        // URLSession queue) can call it directly without hopping to the actor.
        let onProgress = progressHandler
        let name = asrModel.displayName
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = ModelDownloadDelegate(
                destination: destination, modelName: name,
                onProgress: onProgress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    public func transcribe(_ clip: AudioClip) async throws -> ASRTranscript {
        try await prepare()
        guard let session else {
            throw PressayError.modelUnavailable("\(asrModel.displayName) is not loaded")
        }
        let started = ContinuousClock.now
        let text = try await transcribeSegment(
            clip.samples, sampleRate: clip.sampleRate,
            session: session, depth: 0)
        guard !text.isEmpty else { throw PressayError.emptyTranscript }
        return ASRTranscript(
            text: text,
            processingTime: started.duration(to: .now).seconds
        )
    }

    /// Transcribes one segment, splitting it when the decoder context cannot
    /// hold it. Returns "" for a segment that produced nothing usable, so a
    /// hallucinated or empty chunk drops out of the join instead of poisoning
    /// the surrounding real speech.
    private func transcribeSegment(
        _ samples: [Float],
        sampleRate: Int,
        session: Session,
        depth: Int
    ) async throws -> String {
        // Known-too-long input: split before spending a decode on it.
        if let limit = maxRunSamples, samples.count > limit, canSplit(samples, sampleRate, depth) {
            return try await splitAndTranscribe(
                samples, sampleRate: sampleRate, session: session, depth: depth)
        }
        var options = RunOptions()
        options.timestamps = .none
        if asrModel.supportsLanguageHint, language != "auto" {
            options.language = language
        }
        if supportsPnc { options.pnc = .on }
        if supportsItn { options.itn = .on }
        // Safe to send across the await: the model's run lock serializes all
        // runs, and this actor is the session's only owner (the same contract
        // the wrapper's own async overload relies on).
        nonisolated(unsafe) let activeSession = session
        do {
            // The async overload hops the blocking run off this actor; the
            // model's internal run lock serializes reentrant calls, and Task
            // cancellation (our Timeout wrapper) bridges to the native abort.
            let transcript = try await activeSession.run(samples, options: options)
            let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // LLM-style engines answer near-silent audio with a refusal, or an
            // invented sentence in another script. Neither was dictated.
            return asrModel.isTranscriptionRefusal(text) ? "" : text
        } catch TranscribeError.outputTruncated(_, let partial) {
            // Truncation cannot be predicted from input length — a repetition
            // loop can exhaust the context on a three-second clip — so this is
            // a retry path rather than something the length check above cures.
            if canSplit(samples, sampleRate, depth) {
                return try await splitAndTranscribe(
                    samples, sampleRate: sampleRate, session: session, depth: depth)
            }
            // Too short to divide further: keep whatever did decode rather
            // than dropping the words the engine got through.
            let salvaged = (partial?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return asrModel.isTranscriptionRefusal(salvaged) ? "" : salvaged
        }
    }

    private func splitAndTranscribe(
        _ samples: [Float],
        sampleRate: Int,
        session: Session,
        depth: Int
    ) async throws -> String {
        let cut = AudioChunking.splitPoint(samples: samples, sampleRate: sampleRate)
        var parts: [String] = []
        for piece in [Array(samples[..<cut]), Array(samples[cut...])] {
            parts.append(try await transcribeSegment(
                piece, sampleRate: sampleRate, session: session, depth: depth + 1))
        }
        return AudioChunking.join(parts)
    }

    private func canSplit(_ samples: [Float], _ sampleRate: Int, _ depth: Int) -> Bool {
        guard depth < Self.maxSplitDepth, sampleRate > 0 else { return false }
        // Both halves must still be long enough to be worth decoding.
        return Double(samples.count) / Double(sampleRate) >= Self.minimumSplitSeconds * 2
    }
}

/// Reports fractional download progress for a single model artifact and moves
/// the finished file into place. `@unchecked Sendable`: its mutable state is
/// only touched on the URLSession delegate queue (serial) plus a one-shot
/// `resumed` guard.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let modelName: String
    private let onProgress: (@Sendable (Double?) -> Void)?
    private let continuation: CheckedContinuation<Void, Error>
    var session: URLSession?
    private var resumed = false

    init(
        destination: URL, modelName: String,
        onProgress: (@Sendable (Double?) -> Void)?,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.modelName = modelName
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            onProgress?(nil)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // A non-200 (e.g. 404) still "finishes" with an error body — do not keep it.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(PressayError.modelUnavailable("Model download failed for \(modelName)")))
            return
        }
        // `location` is deleted as soon as this method returns, so move it now.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            // Success is normally settled in didFinishDownloadingTo; this is a
            // no-op guard for the already-resumed case.
            finish(.success(()))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !resumed else { return }
        resumed = true
        session?.finishTasksAndInvalidate()
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
