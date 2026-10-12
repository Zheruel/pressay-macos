import AppKit
import Network
import OSLog
import PressayCore

@MainActor
final class ChatGPTAccount: ObservableObject {
    @Published private(set) var credentials: ChatGPTCredentials?
    @Published private(set) var signingIn = false
    @Published private(set) var models: [(slug: String, name: String)] = []
    @Published var lastError: String?

    private let store = ChatGPTCredentialStore()
    private let auth = ChatGPTAuthClient()
    private var refreshTask: Task<ChatGPTCredentials, Error>?
    private var listener: LoopbackListener?
    private let logger = Logger(subsystem: "dev.localflow.app", category: "chatgpt")

    init() {
        credentials = store.load()
    }

    var isSignedIn: Bool { credentials?.planUsageGranted == true }

    /// Reuses this Mac's registration when there is one.
    func signIn() async {
        guard !signingIn else { return }
        signingIn = true
        lastError = nil
        defer { signingIn = false; listener?.stop(); listener = nil }
        do {
            let listener = try LoopbackListener(path: ChatGPTPlan.callbackPath)
            self.listener = listener
            let port = try await listener.start()
            let previous = credentials ?? store.load()
            let attempt = ChatGPTAuthAttempt(
                redirectURI: "http://127.0.0.1:\(port)\(ChatGPTPlan.callbackPath)",
                clientID: previous?.clientID
            )
            let url = attempt.authorizeURL(
                hostID: try store.hostID(),
                idTokenHint: previous?.idToken,
                loginHint: previous?.email
            )
            NSWorkspace.shared.open(url)
            let callback = try await listener.callback()
            let signedIn = try await auth.complete(attempt: attempt, callback: callback)
            try store.save(signedIn)
            credentials = signedIn
            NSApplication.shared.activate(ignoringOtherApps: true)
            await loadModels()
        } catch is CancellationError {
            return
        } catch {
            logger.error("ChatGPT sign-in failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    func cancelSignIn() {
        listener?.cancel()
    }

    func signOut() async {
        guard let credentials else { return }
        refreshTask?.cancel()
        self.credentials = nil
        let revoked = await auth.revoke(credentials)
        if !revoked { logger.notice("ChatGPT revocation not confirmed; cleared locally") }
        store.clear()
        self.credentials = nil
        models = []
    }

    /// Refreshes are serialized because each one rotates the refresh token.
    func accessToken() async throws -> String {
        guard var current = credentials else { throw ChatGPTAuthError.refreshExpired }
        guard current.needsRefresh else { return current.accessToken }
        // Another process may have rotated the tokens; a stale one would sign the user out.
        if let onDisk = store.load(), onDisk.expiresAt > current.expiresAt {
            credentials = onDisk
            current = onDisk
            guard current.needsRefresh else { return current.accessToken }
        }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let auth = auth
        let task = Task { try await auth.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            // Signed out while refreshing.
            guard credentials != nil else { throw ChatGPTAuthError.refreshExpired }
            try store.save(refreshed)
            credentials = refreshed
            return refreshed.accessToken
        } catch ChatGPTAuthError.refreshExpired {
            store.clear()
            credentials = nil
            throw ChatGPTAuthError.refreshExpired
        }
    }

    func loadModels() async {
        guard isSignedIn, let token = try? await accessToken() else { return }
        if let list = try? await ChatGPTCleaner().models(accessToken: token) { models = list }
    }
}

/// One-shot 127.0.0.1 listener for the OAuth redirect; prefers the docs' port 1455.
private final class LoopbackListener: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "dev.localflow.app.oauth")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    init(path: String) throws {
        self.path = path
    }

    func start() async throws -> UInt16 {
        for port in [1455, 0] as [UInt16] {
            if let started = try? await listen(on: port) { return started }
        }
        throw URLError(.cannotConnectToHost)
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // Runs on `queue`, so the flag needs no lock.
            let gate = Gate()
            listener.stateUpdateHandler = { state in
                guard !gate.done else { return }
                switch state {
                case .ready:
                    gate.done = true
                    continuation.resume(returning: listener.port?.rawValue ?? port)
                case .failed(let error):
                    gate.done = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    private final class Gate: @unchecked Sendable { var done = false }

    func callback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) } else { self.continuation = continuation }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func stop() {
        queue.async { self.listener?.cancel() }
    }

    private func finish(_ result: Result<URL, Error>) {
        queue.async {
            guard self.result == nil else { return }
            self.result = result
            self.continuation?.resume(with: result)
            self.continuation = nil
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let matches = target.hasPrefix(self.path + "?")
            let body = matches
                ? "<h2>You're signed in.</h2><p>You can close this tab and return to Pressay.</p>"
                : "<p>Not found.</p>"
            let html = "<!doctype html><meta charset=utf-8><title>Pressay</title>"
                + "<body style=\"font:15px -apple-system;text-align:center;padding:60px\">\(body)</body>"
            let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if matches, let url = URL(string: "http://127.0.0.1\(target)") {
                self.finish(.success(url))
            }
        }
    }
}
