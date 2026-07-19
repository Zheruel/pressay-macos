import Foundation

/// Rewrites a dictated instruction into a well-engineered agent prompt using
/// Kimi. This backs the deliberate prompt-polish hotkey, not the fast
/// dictation path, so multi-second latency is acceptable.
public actor KimiPromptPolishClient {
    public enum PolishError: LocalizedError {
        case emptyResult

        public var errorDescription: String? {
            switch self {
            case .emptyResult: "The Kimi API returned an empty prompt"
            }
        }
    }

    /// Calibrated via `LocalFlowBench kimi-polish` (3-model bakeoff): regular
    /// K2.7 matches highspeed's quality at 1× quota instead of 3×, and beats
    /// k3 on both latency and consistency. Median ~9s, observed worst ~30s.
    public static let model = "kimi-for-coding"

    /// Calibrated via `LocalFlowBench kimi-polish` over historical dictations
    /// (the "structured" variant: verbatim on degenerate inputs, best hedge
    /// preservation). `{text}` is replaced with the cleaned transcript.
    public static let defaultTemplate = """
    You rewrite raw voice dictation into a high-quality prompt for an AI coding or general-purpose agent, applying prompt-engineering best practices.

    Rules:
    - Lead with the direct instruction or question.
    - Keep every fact, constraint, number, URL, name, and technical identifier exactly as dictated. Never invent requirements, details, or acceptance criteria.
    - Group related requirements; use short bullets when the speaker gave multiple parts, plain prose otherwise.
    - Remove fillers, false starts, and self-corrections (keep only the corrected version).
    - Preserve the speaker's uncertainty, hedges, and negations.
    - If the speaker describes the desired output (format, length, audience), keep that as an instruction in the prompt.
    - If the dictation is a lone term or fragment with no discernible request, return it verbatim.
    - Do not answer the prompt. Output only the rewritten prompt, with no commentary.

    <DICTATION>
    {text}
    </DICTATION>
    """

    public init() {}

    public func polish(
        _ text: String,
        template: String = KimiPromptPolishClient.defaultTemplate,
        model: String = KimiPromptPolishClient.model,
        apiKey: String,
        timeout: TimeInterval = 45
    ) async throws -> String {
        let content = try await KimiChatAPI.complete(
            model: model,
            prompt: template.replacingOccurrences(of: "{text}", with: text),
            apiKey: apiKey,
            timeout: timeout
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishError.emptyResult }
        return trimmed
    }
}
