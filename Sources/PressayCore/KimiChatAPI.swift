import Foundation

/// Reasoning controls the Kimi coding API accepts per model family: K3 takes
/// `reasoning_effort`; K2.x takes `thinking.type = disabled` (routing to K2.6).
public enum KimiReasoning: Sendable, Equatable {
    case standard
    case effort(String)
    case thinkingDisabled

    var bodyFields: [String: Any] {
        switch self {
        case .standard: [:]
        case .effort(let level): ["reasoning_effort": level]
        case .thinkingDisabled: ["thinking": ["type": "disabled"]]
        }
    }
}

/// Shared plumbing for the Kimi coding-plan chat-completions API; the tuner
/// and prompt-polish clients differ only in model, prompt, and output parsing.
public enum KimiChatAPI {
    public enum APIError: LocalizedError {
        case http(Int, String)
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): "The Kimi API returned HTTP \(code): \(body)"
            case .badResponse(let detail): "The Kimi API response could not be read: \(detail)"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.kimi.com/coding/v1/chat/completions")!

    /// Sends a single-user-message chat completion and returns the assistant text.
    public static func complete(
        model: String,
        prompt: String,
        apiKey: String,
        timeout: TimeInterval,
        reasoning: KimiReasoning = .standard
    ) async throws -> String {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        body.merge(reasoning.bodyFields) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse("not http") }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return content
    }
}
