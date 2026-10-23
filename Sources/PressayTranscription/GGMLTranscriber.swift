import Foundation
import PressayCore
import TranscribeCpp

public actor GGMLTranscriber: SpeechTranscriber {
    private let asrModel: ASRModel
    private var language: String
    private var session: Session?
    private var preparation: Task<Void, Error>?
    private var statusHandler: (@Sendable (String) -> Void)?
    private var progressHandler: (@Sendable (Double?) -> Void)?
    /// Fun-ASR ships punctuation and ITN off and emits verbatim lowercase otherwise.
    private var supportsPnc = false
    private var supportsItn = false
    /// Seconds (not samples, so it holds at any clip rate); nil when unbounded (Whisper chunks internally).
    private var maxRunSeconds: TimeInterval?

    /// 16 pieces covers ~16 min at 60 s each; exhausting it signals a decode loop, not length.
    private static let maxSplitDepth = 4
    /// Sub-second fragments carry no usable context.
    private static let minimumSplitSeconds: TimeInterval = 1.0

    public init(model: ASRModel, language: String = "auto") {
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
        // The actor suspends across download/load; concurrent prepare() calls join this task.
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
            // Unloadable cache is corrupt (truncated download); drop it so the next prepare() re-downloads.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        // Prewarm Metal pipelines so the first dictation doesn't pay shader compilation.
        nonisolated(unsafe) let warmupSession = fresh
        _ = try? await warmupSession.run([Float](repeating: 0, count: 16_000))

        if asrModel.requestsExplicitFormatting {
            supportsPnc = model.supports(.pnc)
            supportsItn = model.supports(.itn)
        }
        // The GGUF is authoritative; if ASRModel's table drifts, don't send a hint the engine rejects.
        let advertised = model.capabilities.languages
        if language != "auto", !advertised.isEmpty, !advertised.contains(language) {
            language = asrModel.defaultLanguage.whisperCode
        }
        // Lower of the decoder context limit (0 = unbounded) and the model's preferred chunk size.
        let apiLimit = fresh.limits.effectiveMaxAudioMs
        maxRunSeconds = [
            apiLimit > 0 ? Double(apiLimit) / 1000 : nil,
            asrModel.preferredChunkSeconds,
        ].compactMap { $0 }.min()

        session = fresh
        removeUnusedModelArtifacts(in: directory, keeping: destination)
    }

    /// Keeps GGUFs of every shipping model so switching back never re-downloads.
    private func removeUnusedModelArtifacts(in directory: URL, keeping active: URL) {
        let known = Set(ASRModel.allCases.compactMap { $0.ggufDownload?.fileName })
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for url in contents ?? [] where url.pathExtension == "gguf" {
            guard url != active, !known.contains(url.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Delegate-based (not `URLSession.download`) so large artifacts show live progress.
    private func downloadModel(from url: URL, to destination: URL) async throws {
        // @Sendable, so the delegate can call it from the URLSession queue without an actor hop.
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

    /// Returns "" for unusable segments so hallucinated chunks drop out of the join.
    private func transcribeSegment(
        _ samples: [Float],
        sampleRate: Int,
        session: Session,
        depth: Int
    ) async throws -> String {
        // Split up front; reacting to overflow afterwards wastes a whole decode.
        let seconds = sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
        if let limit = maxRunSeconds, seconds > limit, canSplit(samples, sampleRate, depth) {
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
        // Safe to send: the model's run lock serializes runs and this actor is the sole owner.
        nonisolated(unsafe) let activeSession = session
        do {
            // Task cancellation (our Timeout wrapper) bridges to the native abort.
            let transcript = try await activeSession.run(samples, options: options)
            let text = asrModel.plainTranscript(transcript.text)
            // LLM-style engines answer near-silence with a refusal or invented foreign-script text.
            return asrModel.isTranscriptionRefusal(text, language: language) ? "" : text
        } catch TranscribeError.outputTruncated(_, let partial) {
            // A repetition loop can exhaust context even on a 3 s clip, so length checks can't prevent this.
            if canSplit(samples, sampleRate, depth) {
                return try await splitAndTranscribe(
                    samples, sampleRate: sampleRate, session: session, depth: depth)
            }
            // Can't divide further: keep the partial decode rather than drop it.
            let salvaged = asrModel.plainTranscript(partial?.text ?? "")
            return asrModel.isTranscriptionRefusal(salvaged, language: language) ? "" : salvaged
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
        return Double(samples.count) / Double(sampleRate) >= Self.minimumSplitSeconds * 2
    }
}

/// `@unchecked Sendable`: mutable state is only touched on the serial URLSession delegate queue.
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
