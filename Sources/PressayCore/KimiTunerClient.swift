import Foundation

/// Judges tuner candidates with Kimi through the plan-covered coding API.
public actor KimiTunerClient {
    /// K2.7 matches K3 on this judging task at the cheapest usage rate
    /// (validated via `PressayBench tune --with-kimi 1`).
    public static let model = "kimi-for-coding"
    public struct Finding: Sendable {
        public let heard: String
        public let meant: String
    }

    public init() {}

    public func judge(candidates: [TunerCandidate], anchors: [String], apiKey: String) async throws -> [Finding] {
        let content = try await KimiChatAPI.complete(
            model: Self.model,
            prompt: Self.prompt(candidates: candidates, anchors: anchors),
            apiKey: apiKey,
            timeout: 300
        )
        return Self.parseFindings(content)
    }

    public func testConnection(apiKey: String) async throws -> Bool {
        let content = try await KimiChatAPI.complete(
            model: Self.model, prompt: "Reply with exactly: OK", apiKey: apiKey, timeout: 120
        )
        return !content.isEmpty
    }

    public static func prompt(candidates: [TunerCandidate], anchors: [String]) -> String {
        let sections = candidates.map { candidate in
            """
            TERM: "\(candidate.term)" (appears \(candidate.count)x)
            \(candidate.excerpt)
            """
        }.joined(separator: "\n\n")
        return """
        You audit speech-to-text output from a developer who dictates prompts for AI coding agents. Below are candidate TERMS with transcript excerpts. For each TERM, decide whether it is a speech-to-text mishearing of a name, product, or technical term — or a correct/ordinary word to leave alone.

        Rules:
        - Only flag a term when context makes the intended term obvious.
        - Never flag ordinary English words, even unusual ones.
        - Do not flag terms that are already correct, even if rare or project-specific.
        - Prefer corrections from the trusted vocabulary list below when a term matches one of them acoustically.
        - If unsure, do not flag.

        Trusted vocabulary (preferred spellings):
        \(anchors.joined(separator: ", "))

        Reply with a JSON array only, no commentary, no markdown fences. One element per flagged term: {"heard": "...", "meant": "...", "confidence": "high"}.
        If nothing is a clear mishearing, reply with [].

        \(sections)
        """
    }

    public static func parseFindings(_ content: String) -> [Finding] {
        guard let start = content.firstIndex(of: "["),
              let end = content.lastIndex(of: "]"),
              end > start,
              let parsed = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)),
              let array = parsed as? [Any] else {
            return []
        }
        // Tolerate extra fields of any JSON type — models routinely return a
        // numeric confidence despite the prompt asking for a string.
        return array.compactMap { element in
            guard let item = element as? [String: Any],
                  let heard = item["heard"] as? String,
                  let meant = item["meant"] as? String else { return nil }
            return Finding(heard: heard, meant: meant)
        }
    }
}
