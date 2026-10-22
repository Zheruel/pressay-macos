import Foundation
import PressayCore

struct ASRWorkerReply: Sendable {
    let text: String
    let truncated: Bool
}

/// Blocking pipe I/O stays on this serial queue. A request cannot interleave
/// with model replacement; cancellation/timeout terminates the worker and
/// unblocks the read even when a native kernel does not cooperate.
final class ASRWorkerHost: @unchecked Sendable {
    static let shared = ASRWorkerHost()
    private let queue = DispatchQueue(label: "dev.localflow.app.asr-worker", qos: .userInitiated)
    private let executable: URL
    private let runtime: URL
    private let timeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    private var loaded: ASRModel?

    init(executable: URL? = nil, runtime: URL? = nil, timeout: TimeInterval = 180) {
        self.executable = executable ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/PressayASRWorker")
        self.runtime = runtime ?? Bundle.main.bundleURL.appending(path: "Contents/Resources/ASRRuntime")
        self.timeout = timeout
    }

    func release() async {
        await withCheckedContinuation { continuation in
            queue.async { self.stop(); continuation.resume() }
        }
    }

    func request(model: ASRModel, directory: URL, audio: [Float]?) async throws -> ASRWorkerReply {
        let cancellation = WorkerCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try cancellation.check()
                        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                        timer.schedule(deadline: .now() + timeout)
                        timer.setEventHandler { cancellation.cancel(timedOut: true) }
                        timer.resume()
                        defer { cancellation.finish(); timer.cancel() }
                        if loaded != model || process?.isRunning != true {
                            stop()
                            let child = Process(), stdin = Pipe(), stdout = Pipe()
                            child.executableURL = executable
                            child.arguments = [model.rawValue, directory.path, runtime.path]
                            child.standardInput = stdin; child.standardOutput = stdout
                            child.standardError = FileHandle.nullDevice
                            process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
                            // A worker crash must become EPIPE, never terminate
                            // the dictation app with SIGPIPE.
                            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                            try cancellation.attach(child)
                            try child.run()
                            try cancellation.check()
                            let ready = try readReply()
                            guard ready["ready"] as? Bool == true else { throw Self.failure("Speech model did not become ready") }
                            loaded = model
                        } else if let process { try cancellation.attach(process) }
                        guard let audio else {
                            try cancellation.check()
                            continuation.resume(returning: ASRWorkerReply(text: "", truncated: false))
                            return
                        }
                        let pcm = audio.withUnsafeBytes { Data($0).base64EncodedString() }
                        let request = try JSONSerialization.data(withJSONObject: ["pcm": pcm])
                        try input?.write(contentsOf: request + Data([10]))
                        let reply = try readReply()
                        try cancellation.check()
                        guard let text = reply["text"] as? String,
                              let truncated = reply["truncated"] as? Bool else { throw Self.failure("Invalid speech worker reply") }
                        continuation.resume(returning: ASRWorkerReply(text: text, truncated: truncated))
                    } catch {
                        stop()
                        let failure: Error = cancellation.timedOut
                            ? Self.failure("Speech engine timed out. Please try again or choose another model.")
                            : (cancellation.isCancelled ? CancellationError() : error)
                        continuation.resume(throwing: failure)
                    }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func readReply() throws -> [String: Any] {
        while !buffered.contains(10) {
            guard let output else { throw Self.failure("Speech engine is not running") }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { read(output.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw Self.failure("Speech engine stopped. Please try again.")
            }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= 1_048_576 else { throw Self.failure("Oversized speech worker reply") }
        }
        let end = buffered.firstIndex(of: 10)!
        let line = buffered.prefix(upTo: end)
        buffered.removeSubrange(...end)
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw Self.failure("Invalid speech worker reply")
        }
        if let error = reply["error"] as? String { throw Self.failure(error) }
        return reply
    }

    private func stop() {
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
        }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil; loaded = nil; buffered.removeAll()
    }

    deinit { if let process, process.isRunning { process.terminate() } }
    private static func failure(_ text: String) -> PressayError { .modelUnavailable(text) }
}

private final class WorkerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var timeout = false
    private var finished = false
    private var process: Process?
    var isCancelled: Bool { lock.withLock { cancelled } }
    var timedOut: Bool { lock.withLock { timeout } }
    func check() throws { if isCancelled { throw CancellationError() } }
    func attach(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            self.process = process
        }
    }
    func finish() { lock.withLock { finished = true; process = nil } }
    func cancel(timedOut: Bool = false) {
        let child = lock.withLock { () -> Process? in
            guard !finished else { return nil }
            cancelled = true; timeout = timeout || timedOut; return process
        }
        if let child, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
}
