import Foundation
import Darwin
import CryptoKit

public enum ClaudeCodeError: LocalizedError, Equatable {
    case notInstalled, updateRequired, notSignedIn, timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Install Claude Code to use your Claude subscription."
        case .updateRequired: "Update Claude Code to use it with Pressay."
        case .notSignedIn: "Sign in to Claude Code with your Claude subscription."
        case .timedOut: "Claude Code took too long."
        case .failed(let message): message
        }
    }
}

public struct ClaudeCodeAuthStatus: Sendable, Equatable {
    public let loggedIn: Bool
    public let authMethod: String
    public let subscriptionType: String?
    fileprivate let accountIdentity: String?
    public var usesSubscription: Bool { loggedIn && authMethod == "claude.ai" }

    public static func parse(_ data: Data) throws -> Self {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else {
            throw ClaudeCodeError.failed("Could not read Claude Code sign-in status.")
        }
        let identityParts = ["orgId", "email", "subscriptionType"].compactMap { json[$0] as? String }
        let identity = identityParts.isEmpty ? nil
            : SHA256.hash(data: Data(identityParts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(loggedIn: loggedIn, authMethod: json["authMethod"] as? String ?? "none",
                    subscriptionType: json["subscriptionType"] as? String, accountIdentity: identity)
    }
}

/// Runs the published CLI. Authentication remains entirely owned by Claude Code.
public struct ClaudeCodeClient: Sendable {
    public let executable: URL?

    public init(executable: URL? = ClaudeCodeClient.findExecutable()) { self.executable = executable }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    fileprivate var executableIdentity: String? {
        guard let executable else { return nil }
        let resolved = executable.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(resolved.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
    }

    public func checkCapabilities(timeout: TimeInterval = 5) async throws {
        let result = try await run(arguments: ["--help"], timeout: timeout)
        let help = String(decoding: result.stdout, as: UTF8.self)
        guard result.exitCode == 0, Self.supportsCleanup(help) else { throw ClaudeCodeError.updateRequired }
    }

    static func supportsCleanup(_ help: String) -> Bool {
        ["--safe-mode", "--tools", "--disallowedTools", "--no-session-persistence", "--output-format",
         "--system-prompt", "--effort", "--model"].allSatisfy { help.contains($0) }
    }

    public func authStatus(timeout: TimeInterval = 5) async throws -> ClaudeCodeAuthStatus {
        let result = try await run(arguments: ["auth", "status"], timeout: timeout)
        // A normal signed-out status exits 1 but still supplies structured JSON.
        return try ClaudeCodeAuthStatus.parse(result.stdout)
    }

    public func signIn() async throws {
        let result = try await run(arguments: ["auth", "login"], timeout: 180)
        guard result.exitCode == 0 else {
            throw ClaudeCodeError.failed("Claude Code sign-in did not complete. Try signing in from Terminal with claude auth login.")
        }
    }

    func run(arguments: [String], input: String = "", timeout: TimeInterval) async throws -> ClaudeCodeProcessResult {
        guard let executable else { throw ClaudeCodeError.notInstalled }
        return try await ClaudeCodeProcess(executable: executable, arguments: arguments, input: input, timeout: timeout).run()
    }
}

/// A single-use worker. Cancel when ASR ends without cleanup; deinit also cancels it.
public final class ClaudeCodePreparation: @unchecked Sendable {
    private let executableIdentity: String?
    private let system: String
    private let effort: String
    private let started = ContinuousClock.now
    private let validFor: Duration
    private let task: Task<PreparedClaudeCode, Error>
    private let lock = NSLock()
    private var consumed = false
    private var cancelled = false

    init(client: ClaudeCodeClient, system: String, effort: String,
         validFor: Duration = .seconds(55), idleTimeout: TimeInterval = 60) {
        executableIdentity = client.executableIdentity
        self.validFor = validFor
        self.system = system
        self.effort = effort
        task = Task {
            async let capabilities: Void = client.checkCapabilities()
            async let status = client.authStatus()
            try await capabilities
            let account = try await status
            guard account.usesSubscription else { throw ClaudeCodeError.notSignedIn }
            guard let executable = client.executable else { throw ClaudeCodeError.notInstalled }
            let worker = ClaudeCodePendingProcess(executable: executable,
                arguments: ClaudeCodeCleaner.arguments(system: system, effort: effort), idleTimeout: idleTimeout)
            do {
                try await worker.start()
                try Task.checkCancellation()
                return PreparedClaudeCode(worker: worker, accountIdentity: account.accountIdentity)
            } catch { worker.cancel(); throw error }
        }
    }

    public func cancel() {
        lock.withLock { cancelled = true }
        Self.dispose(task)
    }
    deinit { Self.dispose(task) }

    private static func dispose(_ task: Task<PreparedClaudeCode, Error>) {
        task.cancel()
        Task { if let prepared = try? await task.value { prepared.worker.cancel() } }
    }

    fileprivate func use(for client: ClaudeCodeClient, system: String, effort: String,
                         timeout: TimeInterval) async throws -> PreparedClaudeCode? {
        let reusable = try lock.withLock {
            if cancelled { throw CancellationError() }
            guard !consumed, let executableIdentity, executableIdentity == client.executableIdentity,
                  self.system == system, self.effort == effort,
                  started.duration(to: .now) < validFor else { return false }
            consumed = true
            return true
        }
        guard reusable else { cancel(); return nil }
        guard timeout > 0 else { cancel(); throw ClaudeCodeError.timedOut }
        let task = task
        do {
            let prepared = try await withTaskCancellationHandler {
                try await Timeout.run(for: .seconds(timeout)) { try await task.value }
            } onCancel: { Self.dispose(task) }
            try Task.checkCancellation()
            return prepared
        } catch {
            Self.dispose(task)
            if case ClaudeCodeError.notSignedIn = error { return nil }
            if case PressayError.timedOut = error { throw ClaudeCodeError.timedOut }
            throw error
        }
    }
}

private struct PreparedClaudeCode: Sendable {
    let worker: ClaudeCodePendingProcess
    let accountIdentity: String?
}

public struct ClaudeCodeCleaner: Sendable {
    private let client: ClaudeCodeClient
    public init(client: ClaudeCodeClient = ClaudeCodeClient()) { self.client = client }

    /// Start while ASR is doing real work. Vocabulary and effort must match the eventual cleanup.
    /// Authentication is checked again before sending text; changed accounts get a fresh process.
    public func prepare(vocabulary: [VocabularyParser.Entry] = [], effort: String = ClaudeCleanupModel.dictationEffort) -> ClaudeCodePreparation {
        ClaudeCodePreparation(client: client, system: ClaudeCleanupPrompt.system(vocabulary: vocabulary), effort: effort)
    }

    public func clean(
        _ transcript: String, targetBundleID: String?, vocabulary: [VocabularyParser.Entry],
        effort: String, timeout: TimeInterval, preparation: ClaudeCodePreparation? = nil
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let system = ClaudeCleanupPrompt.system(vocabulary: vocabulary)
        let prepared = try await preparation?.use(for: client, system: system, effort: effort,
                                                  timeout: deadline.timeIntervalSinceNow)
        defer { prepared?.worker.cancel() }
        if prepared == nil {
            try await client.checkCapabilities(timeout: min(5, deadline.timeIntervalSinceNow))
        }
        let account = try await client.authStatus(timeout: min(5, deadline.timeIntervalSinceNow))
        guard account.usesSubscription else { throw ClaudeCodeError.notSignedIn }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw ClaudeCodeError.timedOut }
        let input = ClaudeCleanupPrompt.user(transcript: transcript, targetBundleID: targetBundleID)
        let result: ClaudeCodeProcessResult
        if let prepared, let identity = prepared.accountIdentity, identity == account.accountIdentity {
            do {
                result = try await prepared.worker.submit(input: input, timeout: remaining)
            } catch ClaudeCodePreparationError.workerExited {
                // Native CLI versions may stop waiting for the first stdin byte after a few
                // seconds. No transcript was sent, so restarting cannot duplicate a request.
                prepared.worker.cancel()
                result = try await client.run(arguments: Self.arguments(system: system, effort: effort),
                    input: input, timeout: deadline.timeIntervalSinceNow)
            }
        } else {
            prepared?.worker.cancel()
            result = try await client.run(arguments: Self.arguments(system: system, effort: effort),
                                          input: input, timeout: remaining)
        }
        let cleaned = try Self.parseReply(result.stdout, exitCode: result.exitCode)
        guard ClaudeCleanupPolicy.isPlausibleEdit(of: transcript, output: cleaned) else {
            throw ClaudeCleaner.CleanupError.implausible
        }
        return cleaned
    }

    static func arguments(system: String, effort: String) -> [String] {
        ["-p", "--safe-mode", "--tools", "", "--disallowedTools", "mcp__*",
         "--no-session-persistence", "--output-format", "json",
         "--model", "claude-haiku-5-5", "--effort", effort, "--system-prompt", system]
    }

    static func parseReply(_ data: Data, exitCode: Int32) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "result" else {
            throw ClaudeCodeError.failed("Claude Code did not return a cleanup result.")
        }
        guard exitCode == 0, json["is_error"] as? Bool != true,
              json["subtype"] as? String == "success" else {
            // Do not surface raw provider output: it can contain the dictation or account details.
            throw ClaudeCodeError.failed("Claude Code could not finish cleanup. Check your sign-in and plan limits.")
        }
        if let stop = json["stop_reason"] as? String, stop != "end_turn" {
            throw ClaudeCodeError.failed("Claude Code stopped before cleanup was complete.")
        }
        guard let text = json["result"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClaudeCodeError.failed("Claude Code returned an empty cleanup result.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ClaudeCodeProcessResult: Sendable {
    let stdout: Data
    let exitCode: Int32
}

/// Regular files avoid pipe-buffer deadlocks with large input or output.
final class ClaudeCodeProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.localflow.claude-process")
    private let executable: URL
    private let arguments: [String]
    private let input: String
    private let timeout: TimeInterval
    private var process: Process?
    private var directory: URL?
    private var handles: [FileHandle] = []
    private var continuation: CheckedContinuation<ClaudeCodeProcessResult, Error>?
    private var timer: DispatchSourceTimer?
    private var cancelled = false
    private var finished = false

    init(executable: URL, arguments: [String], input: String, timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.timeout = timeout
    }

    func run() async throws -> ClaudeCodeProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.stop(CancellationError())
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<ClaudeCodeProcessResult, Error>) {
        self.continuation = continuation
        guard !cancelled else { finish(.failure(CancellationError())); return }
        guard timeout > 0 else { finish(.failure(ClaudeCodeError.timedOut)); return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pressay-Claude-\(UUID().uuidString)")
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let inputURL = directory.appendingPathComponent("input")
            let outputURL = directory.appendingPathComponent("output")
            let errorURL = directory.appendingPathComponent("error")
            try Data(input.utf8).write(to: inputURL)
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let stdin = try FileHandle(forReadingFrom: inputURL)
            handles.append(stdin)
            let stdout = try FileHandle(forWritingTo: outputURL)
            handles.append(stdout)
            let stderr = try FileHandle(forWritingTo: errorURL)
            handles.append(stderr)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            // Inherit authentication configuration unchanged. Never read credentials ourselves.
            self.process = process
            try process.run()
            let deadline = DispatchTime.now() + timeout
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler {
                guard !self.finished else { return }
                if !process.isRunning {
                    do {
                        let data = try Data(contentsOf: outputURL)
                        self.finish(.success(ClaudeCodeProcessResult(stdout: data, exitCode: process.terminationStatus)))
                    } catch { self.finish(.failure(error)) }
                } else if DispatchTime.now() >= deadline {
                    self.stop(ClaudeCodeError.timedOut)
                }
            }
            timer.resume()
        } catch { finish(.failure(error)) }
    }

    private func stop(_ error: Error) {
        guard continuation != nil, !finished else { return }
        if let process, process.isRunning {
            process.terminate()
            // A stuck CLI must not keep a timeout task group or the UI waiting.
            queue.asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<ClaudeCodeProcessResult, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        for handle in handles { try? handle.close() }
        handles = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        continuation?.resume(with: result)
        continuation = nil
    }
}

private enum ClaudeCodePreparationError: Error { case workerExited }

/// Keeps stdin open until the transcript is ready, without blocking cancellation.
private final class ClaudeCodePendingProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.localflow.claude-pending")
    private let executable: URL
    private let arguments: [String]
    private let idleTimeout: TimeInterval
    private var process: Process?
    private var directory: URL?
    private var outputURL: URL?
    private var input: FileHandle?
    private var writer: DispatchSourceWrite?
    private var pendingInput = Data()
    private var inputOffset = 0
    private var handles: [FileHandle] = []
    private var deadline: DispatchWorkItem?
    private var result: Result<ClaudeCodeProcessResult, Error>?
    private var continuation: CheckedContinuation<ClaudeCodeProcessResult, Error>?
    private var cancelled = false
    private var submitted = false

    init(executable: URL, arguments: [String], idleTimeout: TimeInterval = 60) {
        self.executable = executable; self.arguments = arguments; self.idleTimeout = idleTimeout
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !self.cancelled else { ready.resume(throwing: CancellationError()); return }
                    do {
                        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pressay-Claude-\(UUID().uuidString)")
                        self.directory = directory
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                        let outputURL = directory.appendingPathComponent("output")
                        self.outputURL = outputURL
                        let errorURL = directory.appendingPathComponent("error")
                        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                        let stdout = try FileHandle(forWritingTo: outputURL)
                        self.handles.append(stdout)
                        let stderr = try FileHandle(forWritingTo: errorURL)
                        self.handles.append(stderr)
                        let pipe = Pipe()
                        self.input = pipe.fileHandleForWriting
                        let fd = pipe.fileHandleForWriting.fileDescriptor
                        guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1,
                              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        // Claude Code stops waiting after three seconds if stdin has no first
                        // byte. A newline keeps it waiting for the transcript and EOF without
                        // supplying a prompt or starting an inference request.
                        var newline: UInt8 = 10
                        guard Darwin.write(fd, &newline, 1) == 1 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        let process = Process()
                        process.executableURL = self.executable
                        process.arguments = self.arguments
                        process.currentDirectoryURL = directory
                        process.standardInput = pipe.fileHandleForReading
                        process.standardOutput = stdout
                        process.standardError = stderr
                        process.terminationHandler = { [weak self] child in
                            self?.queue.async { [weak self] in self?.exited(child.terminationStatus) }
                        }
                        self.process = process
                        try process.run()
                        try? pipe.fileHandleForReading.close()
                        self.setDeadline(self.idleTimeout)
                        ready.resume()
                    } catch {
                        self.finish(.failure(error))
                        ready.resume(throwing: error)
                    }
                }
            }
        } onCancel: { self.cancel() }
    }

    func submit(input text: String, timeout: TimeInterval) async throws -> ClaudeCodeProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if self.cancelled { continuation.resume(throwing: CancellationError()); return }
                    if !self.submitted && (self.result != nil || self.process?.isRunning != true) {
                        continuation.resume(throwing: ClaudeCodePreparationError.workerExited)
                        return
                    }
                    if let result = self.result { continuation.resume(with: result); return }
                    guard !self.submitted, let input = self.input else {
                        continuation.resume(throwing: ClaudeCodeError.failed("Claude Code preparation was already used."))
                        return
                    }
                    self.submitted = true
                    self.continuation = continuation
                    guard timeout > 0 else { self.stop(ClaudeCodeError.timedOut); return }
                    self.setDeadline(timeout)
                    guard text.utf8.count <= 10 * 1024 * 1024 else {
                        self.stop(ClaudeCodeError.failed("Dictation is too long for Claude Code cleanup."))
                        return
                    }
                    self.pendingInput = Data(text.utf8)
                    let writer = DispatchSource.makeWriteSource(fileDescriptor: input.fileDescriptor, queue: self.queue)
                    self.writer = writer
                    writer.setEventHandler { [weak self] in self?.writeAvailableInput() }
                    writer.setCancelHandler { try? input.close() }
                    writer.resume()
                }
            }
        } onCancel: { self.cancel() }
    }

    private func writeAvailableInput() {
        guard result == nil, let input else { return }
        // Bound each callback so timeout/cancel events cannot be starved by a large transcript.
        for _ in 0..<4 {
            let remaining = pendingInput.count - inputOffset
            guard remaining > 0 else { closeInput(); return }
            let count = pendingInput.withUnsafeBytes { bytes in
                Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: inputOffset), min(16_384, remaining))
            }
            if count > 0 { inputOffset += count }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { return }
            else { stop(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)); return }
        }
    }

    private func closeInput() {
        if let writer {
            writer.cancel() // Its cancel handler closes the fd after pending events have drained.
            self.writer = nil
        } else { try? input?.close() }
        input = nil
        pendingInput = Data()
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.stop(CancellationError())
        }
    }

    private func setDeadline(_ seconds: TimeInterval) {
        deadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.stop(ClaudeCodeError.timedOut) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + seconds, execute: deadline)
    }

    private func exited(_ code: Int32) {
        guard result == nil else { return }
        do {
            guard let outputURL else { throw ClaudeCodeError.failed("Claude Code did not start.") }
            finish(.success(ClaudeCodeProcessResult(stdout: try Data(contentsOf: outputURL), exitCode: code)))
        } catch { finish(.failure(error)) }
    }

    private func stop(_ error: Error) {
        guard result == nil else { return }
        if let process, process.isRunning {
            process.terminate()
            queue.asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<ClaudeCodeProcessResult, Error>) {
        guard self.result == nil else { return }
        self.result = result
        deadline?.cancel(); deadline = nil
        closeInput()
        for handle in handles { try? handle.close() }
        handles = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        continuation?.resume(with: result)
        continuation = nil
    }
}
