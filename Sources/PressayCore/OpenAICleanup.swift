import Foundation

/// A connection has exactly one reader. Closing a retired connection cannot affect its replacement.
protocol OpenAICleanupSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
    func close()
}

private struct ResponsesSocket: OpenAICleanupSocket {
    let task: URLSessionWebSocketTask

    func send(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw URLError(.cannotParseResponse)
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

/// Dictation uses Fast on both transports, with an independent response for every utterance.
public actor OpenAICleaner {
    typealias SocketFactory = @Sendable (String) -> any OpenAICleanupSocket
    typealias HTTPStream = @Sendable (Data, String, TimeInterval) async throws -> String
    private let makeSocket: SocketFactory
    private let httpStream: HTTPStream
    private var socket: (id: UUID, credential: String, connection: any OpenAICleanupSocket)?
    private var lease: UUID?
    private var warming: (id: UUID, task: Task<Void, Error>)?
    private var generation = UUID()

    public init(session: URLSession = .shared) {
        makeSocket = { credential in
            var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/responses")!)
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization")
            let task = session.webSocketTask(with: request)
            task.resume()
            return ResponsesSocket(task: task)
        }
        httpStream = { data, credential, timeout in
            try await Self.streamHTTP(data, credential: credential, timeout: timeout, session: session)
        }
    }

    init(makeSocket: @escaping SocketFactory, httpStream: @escaping HTTPStream) {
        self.makeSocket = makeSocket
        self.httpStream = httpStream
    }

    public static func requestBody(
        transcript: String, targetBundleID: String?, vocabulary: [VocabularyParser.Entry], webSocket: Bool
    ) -> [String: Any] {
        var body = ChatGPTCleaner.requestBody(
            transcript: transcript, targetBundleID: targetBundleID, vocabulary: vocabulary,
            model: ChatGPTCleanupModel.dictationSlug, effort: ChatGPTCleanupModel.dictationEffort
        )
        body["service_tier"] = "priority"
        if webSocket {
            body.removeValue(forKey: "stream")
            body["type"] = "response.create"
        }
        return body
    }

    public func invalidate() {
        generation = UUID()
        warming?.task.cancel()
        warming = nil
        socket?.connection.close()
        socket = nil
        lease = nil
    }

    private func connection(for credential: String) -> (id: UUID, connection: any OpenAICleanupSocket) {
        if let socket, socket.credential != credential { invalidate() }
        if socket == nil { socket = (UUID(), credential, makeSocket(credential)) }
        return (socket!.id, socket!.connection)
    }

    private func retire(_ id: UUID) {
        guard socket?.id == id else { return }
        socket?.connection.close()
        socket = nil
    }

    public func warmUp(credential: String) async {
        guard lease == nil, !credential.isEmpty else { return }
        let current = connection(for: credential)
        if let warming, warming.id == current.id {
            _ = try? await warming.task.value
            return
        }
        // A ping only establishes/checks the connection; it never creates a model response.
        let task = Task {
            try await Timeout.run(for: .seconds(3)) {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await current.connection.ping()
                } onCancel: { current.connection.close() }
            }
        }
        warming = (current.id, task)
        defer { if warming?.id == current.id { warming = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value }
            onCancel: { task.cancel() }
        } catch { retire(current.id) }
    }

    public func clean(
        _ transcript: String, targetBundleID: String?, vocabulary: [VocabularyParser.Entry],
        credential: String, timeout: TimeInterval
    ) async throws -> String {
        try Task.checkCancellation()
        guard timeout > 0 else { throw PressayError.timedOut }
        if let socket, socket.credential != credential { invalidate() }
        let requestGeneration = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let httpData = try JSONSerialization.data(withJSONObject: Self.requestBody(
            transcript: transcript, targetBundleID: targetBundleID, vocabulary: vocabulary, webSocket: false))
        var cleaned: String?
        // Concurrent callers use HTTP, never another reader on the shared socket.
        if lease == nil {
            let current = connection(for: credential)
            let preparation = warming?.id == current.id ? warming?.task : nil
            lease = current.id
            defer { if lease == current.id { lease = nil } }
            let wsData = try JSONSerialization.data(withJSONObject: Self.requestBody(
                transcript: transcript, targetBundleID: targetBundleID, vocabulary: vocabulary, webSocket: true))
            do {
                // A healthy response may need the whole budget. Fall back only when transport
                // failure leaves time; an expired global deadline must not start another request.
                let remaining = ContinuousClock.now.duration(to: deadline).seconds
                guard remaining > 0 else { throw PressayError.timedOut }
                cleaned = try await Timeout.run(for: .seconds(remaining)) {
                    try await withTaskCancellationHandler {
                        try Task.checkCancellation()
                        if let preparation { try await preparation.value }
                        try Task.checkCancellation()
                        try await current.connection.send(wsData)
                        var reader = SSEReader()
                        while true {
                            try Task.checkCancellation()
                            let data = try await current.connection.receive()
                            guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                throw URLError(.cannotParseResponse)
                            }
                            if let result = try Self.handle(event, into: &reader) { return result }
                        }
                    } onCancel: {
                        preparation?.cancel()
                        current.connection.close()
                    }
                }
            } catch {
                retire(current.id)
                try Task.checkCancellation()
                guard generation == requestGeneration else { throw CancellationError() }
                // A terminal API result, refusal or invalid edit must never cause a second billable call.
                if error is ChatGPTCleaner.CleanupError { throw error }
            }
        }
        guard generation == requestGeneration else { throw CancellationError() }
        if cleaned == nil {
            let remaining = ContinuousClock.now.duration(to: deadline).seconds
            guard remaining > 0 else { throw PressayError.timedOut }
            let stream = httpStream
            cleaned = try await Timeout.run(for: .seconds(remaining)) {
                try await stream(httpData, credential, remaining)
            }
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let result = (cleaned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClaudeCleanupPolicy.isPlausibleEdit(of: transcript, output: result) else {
            throw ChatGPTCleaner.CleanupError.implausible
        }
        return result
    }

    static func handle(_ event: [String: Any], into reader: inout SSEReader) throws -> String? {
        if (event["type"] as? String)?.hasPrefix("response.refusal.") == true {
            throw ChatGPTCleaner.CleanupError.failed("refusal")
        }
        if event["type"] as? String == "response.completed",
           let response = event["response"] as? [String: Any],
           let status = response["status"] as? String, status != "completed" {
            throw ChatGPTCleaner.CleanupError.incomplete
        }
        return try ChatGPTCleaner.handle(event, into: &reader)
    }

    private static func streamHTTP(
        _ data: Data, credential: String, timeout: TimeInterval, session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: ChatGPTPlan.responsesEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = data
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 2000 { break }
            }
            throw ChatGPTCleaner.error(status: status, body: body)
        }
        var reader = SSEReader()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = reader.feed(line) else { continue }
            if let result = try handle(event, into: &reader) { return result }
        }
        throw ChatGPTCleaner.CleanupError.incomplete
    }
}
