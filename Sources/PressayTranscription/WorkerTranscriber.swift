import Foundation
import CryptoKit
import PressayCore

public actor WorkerTranscriber: SpeechTranscriber {
    private let model: ASRModel
    private var directory: URL?
    private var preparation: Task<URL, Error>?
    private var status: (@Sendable (String) -> Void)?
    private var progress: (@Sendable (Double?) -> Void)?
    private let host: ASRWorkerHost

    public init(model: ASRModel, bundleURL: URL? = nil) {
        self.model = model
        if let bundleURL {
            host = ASRWorkerHost(executable: bundleURL.appending(path: "Contents/MacOS/PressayASRWorker"),
                runtime: bundleURL.appending(path: "Contents/Resources/ASRRuntime"))
        } else { host = .shared }
    }
    public static func releaseResidentModel() async { await ASRWorkerHost.shared.release() }
    public var engineName: String { model.displayName }
    public func setLanguage(_ language: String) {} // Benchmarked English configurations.
    public func setStatusHandler(_ handler: @escaping @Sendable (String) -> Void) { status = handler }
    public func setProgressHandler(_ handler: @escaping @Sendable (Double?) -> Void) { progress = handler }

    public func prepare() async throws {
        let directory = try await assets()
        status?("Loading \(model.displayName)…")
        do {
            _ = try await host.request(model: model, directory: directory, audio: nil)
        } catch {
            if !Task.isCancelled {
                self.directory = nil
                await ASRArtifactStore.shared.invalidate(model)
            }
            throw error
        }
        progress?(nil)
    }

    private func assets() async throws -> URL {
        if let directory { return directory }
        if let preparation { return try await preparation.value }
        let model = model, status = status, progress = progress
        let task = Task { try await ASRArtifactStore.shared.prepare(model, status: status, progress: progress) }
        preparation = task
        defer { preparation = nil }
        let result = try await task.value
        directory = result
        return result
    }

    public func transcribe(_ clip: AudioClip) async throws -> ASRTranscript {
        guard clip.sampleRate == 16_000, !clip.samples.isEmpty else { throw PressayError.emptyTranscript }
        let directory = try await assets()
        let start = ContinuousClock.now
        let text = try await segment(clip.samples, directory: directory, depth: 0)
        guard !text.isEmpty else { throw PressayError.emptyTranscript }
        return ASRTranscript(text: text, processingTime: start.duration(to: .now).seconds)
    }

    private func segment(_ samples: [Float], directory: URL, depth: Int) async throws -> String {
        try Task.checkCancellation()
        // Bound the Mega router's positional window to 25 seconds.
        if samples.count > 25 * 16_000 { return try await split(samples, directory: directory, depth: depth) }
        let result = try await host.request(model: model, directory: directory, audio: samples)
        if result.truncated {
            if depth < 6, samples.count >= 2 * 16_000 {
                return try await split(samples, directory: directory, depth: depth)
            }
            throw PressayError.modelUnavailable("\(model.displayName) could not finish this audio. Try another model.")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isTranscriptionRefusal(text) ? "" : text
    }

    private func split(_ samples: [Float], directory: URL, depth: Int) async throws -> String {
        let cut = AudioChunking.splitPoint(samples: samples, sampleRate: 16_000)
        let left = try await segment(Array(samples[..<cut]), directory: directory, depth: depth + 1)
        let right = try await segment(Array(samples[cut...]), directory: directory, depth: depth + 1)
        return AudioChunking.join([left, right])
    }
}

private actor ASRArtifactStore {
    static let shared = ASRArtifactStore()
    // Coalesce downloads across reentrant preparation calls.
    private var tasks: [ASRModel: Task<URL, Error>] = [:]

    func invalidate(_ model: ASRModel) { tasks[model] = nil }

    func prepare(_ model: ASRModel, status: (@Sendable (String) -> Void)?,
                 progress: (@Sendable (Double?) -> Void)?) async throws -> URL {
        if let task = tasks[model] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Pressay/Models/ASR/\(model.rawValue)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let artifacts = model.workerArtifacts
            guard !artifacts.isEmpty else { throw PressayError.modelUnavailable("No artifacts for \(model.displayName)") }
            var completed: Int64 = 0
            let total = model.downloadBytes
            for artifact in artifacts {
                let target = root.appending(path: artifact.path)
                if !(try Self.valid(target, artifact: artifact)) {
                    status?("Downloading \(model.displayName)…")
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let done = completed
                    let downloaded = try await ArtifactDownload.download(artifact.url) { fraction in
                        progress?(fraction.map { (Double(done) + $0 * Double(artifact.bytes)) / Double(total) })
                    }
                    defer { try? FileManager.default.removeItem(at: downloaded) }
                    guard try Self.valid(downloaded, artifact: artifact) else {
                        throw PressayError.modelUnavailable("\(model.displayName) download failed its integrity check. Try again.")
                    }
                    if FileManager.default.fileExists(atPath: target.path) {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: downloaded)
                    } else { try FileManager.default.moveItem(at: downloaded, to: target) }
                }
                completed += artifact.bytes
                progress?(Double(completed) / Double(total))
            }
            progress?(nil)
            return model == .megaASR ? root : root.appending(path: artifacts[0].path)
        }
        tasks[model] = task
        do { return try await task.value }
        catch { tasks[model] = nil; throw error }
    }

    private nonisolated static func valid(_ file: URL, artifact: ASRArtifact) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path),
              (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == artifact.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256
    }
}

private final class ArtifactDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Double?) -> Void
    let continuation: CheckedContinuation<URL, Error>
    var session: URLSession?
    var finished = false // Accessed only on the serial delegate queue.
    init(progress: @escaping @Sendable (Double?) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress; self.continuation = continuation
    }
    static func download(_ url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = ArtifactDownload(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            return finish(.failure(PressayError.modelUnavailable("Model download failed. Please try again.")))
        }
        do {
            let saved = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: saved)
            finish(.success(saved))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }; finished = true
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}
