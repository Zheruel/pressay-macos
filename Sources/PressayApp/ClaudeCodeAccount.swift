import Foundation
import PressayCore

@MainActor
final class ClaudeCodeAccount: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var signingIn = false
    @Published private(set) var authMethod: String?
    @Published private(set) var subscriptionType: String?
    @Published var lastError: String?
    private var signInTask: Task<Void, Error>?

    init() {
        #if DEBUG
        guard !DesignReview.enabled else { return }
        #endif
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        #if DEBUG
        guard !DesignReview.enabled else { return }
        #endif
        let client = ClaudeCodeClient()
        isAvailable = client.executable != nil
        isSignedIn = false
        authMethod = nil
        subscriptionType = nil
        guard isAvailable else { return }
        do {
            try await client.checkCapabilities()
            let status = try await client.authStatus()
            authMethod = status.authMethod
            subscriptionType = status.subscriptionType
            isSignedIn = status.usesSubscription
            lastError = status.loggedIn && !status.usesSubscription
                ? "Claude Code is using API billing. Sign in with your Claude subscription, or choose API key in Pressay."
                : nil
        } catch is CancellationError {
            return
        } catch { lastError = error.localizedDescription }
    }

    func signIn() async {
        #if DEBUG
        guard !DesignReview.enabled else { return }
        #endif
        guard !signingIn else { return }
        signingIn = true
        lastError = nil
        defer { signingIn = false; signInTask = nil }
        let client = ClaudeCodeClient()
        let task = Task { try await client.signIn() }
        signInTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await refreshStatus()
        } catch is CancellationError {
            return
        } catch { lastError = error.localizedDescription }
    }

    func cancelSignIn() { signInTask?.cancel() }
}
