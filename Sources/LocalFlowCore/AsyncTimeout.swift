import Foundation

public enum Timeout {
    public static func run<T: Sendable>(
        for duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = TimeoutRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.register(continuation)

                let operationTask = Task<Void, Never> {
                    do {
                        race.resolve(.success(try await operation()))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task<Void, Never> {
                    do {
                        try await Task.sleep(for: duration)
                        race.resolve(.failure(LocalFlowError.timedOut))
                    } catch {
                        // The timeout task is expected to be cancelled when the
                        // operation wins the race.
                    }
                }
                race.install(operationTask: operationTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

/// Uses unstructured tasks so returning the timeout result does not wait for a
/// cancellation-unaware Core ML operation to finish unwinding.
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func register(_ continuation: CheckedContinuation<T, Error>) {
        let resolved: Result<T, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let resolved { continuation.resume(with: resolved) }
    }

    func install(operationTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        let alreadyResolved = lock.withLock {
            guard result == nil else { return true }
            self.operationTask = operationTask
            self.timeoutTask = timeoutTask
            return false
        }
        if alreadyResolved {
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    func resolve(_ result: Result<T, Error>) {
        let state: (
            continuation: CheckedContinuation<T, Error>?,
            operationTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        )? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            let state = (continuation, operationTask, timeoutTask)
            continuation = nil
            operationTask = nil
            timeoutTask = nil
            return state
        }
        guard let state else { return }
        state.operationTask?.cancel()
        state.timeoutTask?.cancel()
        state.continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
