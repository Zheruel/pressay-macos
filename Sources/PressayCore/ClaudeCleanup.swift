import Foundation

/// Optional Claude cleanup. Only transcript text leaves the Mac, never audio, and only with a saved key.
public enum ClaudeCleanupModel: String, CaseIterable, Identifiable, Sendable {
    case haiku55
    case sonnet55

    public static let `default`: ClaudeCleanupModel = .haiku55
    public static let dictationEffort = "low"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sonnet55: "Claude Sonnet 5.5"
        case .haiku55: "Claude Haiku 5.5"
        }
    }

    public var caption: String {
        switch self {
        case .sonnet55: "Best quality · adds about 1.3 s"
        case .haiku55: "Faster · adds about 1 s · slightly lighter edits"
        }
    }

    var apiModel: String {
        switch self {
        case .sonnet55: "claude-sonnet-5-5"
        case .haiku55: "claude-haiku-5-5"
        }
    }

    /// Low kept Haiku fast without a consistent fidelity loss in the Hex-prompt replay.
    var requestFields: [String: Any] {
        [
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": self == .haiku55 ? Self.dictationEffort : "medium"],
        ]
    }
}

public enum ClaudeCleanupPolicy {
    /// Under ten words the AI returned the on-device result unchanged on 8 of 9 benchmark dictations
    /// and was never judged better, so the ~1.2 s round trip only adds delay.
    public static let minimumWords = 10

    public static func shouldClean(_ text: String, isTerminal: Bool) -> Bool {
        !isTerminal && wordCount(text) >= minimumWords
    }

    public static func timeout(for text: String) -> TimeInterval {
        min(8, 3 + Double(wordCount(text)) * 0.01)
    }

    /// Rejects answers, refusals and truncations so they fall back to the rules output.
    public static func isPlausibleEdit(of input: String, output: String) -> Bool {
        let inWords = wordCount(input)
        let outWords = wordCount(output)
        guard outWords > 0 else { return false }
        guard inWords >= 8 else { return outWords <= inWords * 3 + 6 }
        return Double(outWords) >= Double(inWords) * 0.35
            && Double(outWords) <= Double(inWords) * 1.6 + 10
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

public enum ClaudeCleanupPrompt {
    /// Deduplicated by preferred spelling so aliases share one user-provided term.
    public static func vocabularyBlock(_ entries: [VocabularyParser.Entry]) -> String {
        var order: [String] = []
        var aliases: [String: [String]] = [:]
        for entry in entries {
            let preferred = entry.preferred.trimmingCharacters(in: .whitespaces)
            guard !preferred.isEmpty else { continue }
            if aliases[preferred] == nil {
                order.append(preferred)
                aliases[preferred] = []
            }
            for alias in entry.aliases where !aliases[preferred]!.contains(alias) {
                aliases[preferred]!.append(alias)
            }
        }
        return order.map { term in
            let heard = aliases[term]!
            return heard.isEmpty ? term : "\(term) (may be transcribed as \(heard.joined(separator: ", ")))"
        }.joined(separator: "; ")
    }

    public static func system(vocabulary: [VocabularyParser.Entry]) -> String {
        let terms = vocabularyBlock(vocabulary)
        return template + (terms.isEmpty ? "" : "\n\nVocabulary (spell these exactly when the speaker means them): \(terms)")
    }

    public static func user(transcript: String, targetBundleID: String?) -> String {
        "Foreground application: \(targetBundleID ?? "unknown")\nBrowser host: none\n\nRaw transcript:\n<transcript>\n\(transcript)\n</transcript>"
    }

    /// Hex's default dictation prompt, with its protocol and profile instructions.
    /// https://github.com/anomalyco/hex/blob/dev/src/dictation_processor.rs
    static let template = """
    You transform dictated speech into replacement text. Return only the text that should be pasted. Do not add an explanation, label, alternative, or Markdown fence.

    Profile instructions:
    Rewrite the transcript into clear, natural text while preserving the speaker's intended meaning.
    """

}

public struct ClaudeCleaner: Sendable {
    public enum CleanupError: LocalizedError, Equatable {
        case http(Int, String)
        case badResponse(String)
        case stopped(String)
        case implausible

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): "Claude returned HTTP \(code): \(body)"
            case .badResponse(let detail): "Claude's response could not be read: \(detail)"
            case .stopped(let reason): "Claude stopped early (\(reason))"
            case .implausible: "Claude's reply did not look like an edit of the dictation"
            }
        }
    }

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    static let apiVersion = "2023-06-01"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func requestBody(
        transcript: String,
        targetBundleID: String?,
        vocabulary: [VocabularyParser.Entry],
        model: ClaudeCleanupModel
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.apiModel,
            "max_tokens": 4000,
            // Stable per vocabulary, so the instructions are a cache read.
            "system": [[
                "type": "text",
                "text": ClaudeCleanupPrompt.system(vocabulary: vocabulary),
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [[
                "role": "user",
                "content": ClaudeCleanupPrompt.user(transcript: transcript, targetBundleID: targetBundleID),
            ]],
        ]
        body.merge(model.requestFields) { _, new in new }
        return body
    }

    static func makeRequest(url: URL, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return request
    }

    /// Anything but a normal end is an error, so a refusal or truncation never replaces the user's words.
    static func parseReply(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw CleanupError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        let stop = json["stop_reason"] as? String ?? "unknown"
        guard stop == "end_turn" else { throw CleanupError.stopped(stop) }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CleanupError.badResponse("empty text") }
        return text
    }

    public func clean(
        _ transcript: String,
        targetBundleID: String?,
        vocabulary: [VocabularyParser.Entry],
        model: ClaudeCleanupModel,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> String {
        var request = Self.makeRequest(url: Self.endpoint, apiKey: apiKey, timeout: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(
            transcript: transcript,
            targetBundleID: targetBundleID,
            vocabulary: vocabulary,
            model: model
        ))
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CleanupError.badResponse("not http") }
        guard http.statusCode == 200 else {
            throw CleanupError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        let cleaned = try Self.parseReply(data)
        guard ClaudeCleanupPolicy.isPlausibleEdit(of: transcript, output: cleaned) else {
            throw CleanupError.implausible
        }
        return cleaned
    }

    public func complete(
        system: String,
        user: String,
        model: ClaudeCleanupModel,
        apiKey: String,
        timeout: TimeInterval
    ) async throws -> String {
        var request = Self.makeRequest(url: Self.endpoint, apiKey: apiKey, timeout: timeout)
        request.httpMethod = "POST"
        var body: [String: Any] = [
            "model": model.apiModel,
            "max_tokens": 16_000,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": user]],
        ]
        body.merge(model.requestFields) { _, new in new }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CleanupError.badResponse("not http") }
        guard http.statusCode == 200 else {
            throw CleanupError.http(http.statusCode, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try Self.parseReply(data)
    }

    /// Opens TLS while the user speaks so cleanup skips the handshake; also the Settings connection test.
    @discardableResult
    public func warmUp(apiKey: String) async throws -> Int {
        var request = Self.makeRequest(url: Self.modelsEndpoint, apiKey: apiKey, timeout: 5)
        request.httpMethod = "GET"
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
