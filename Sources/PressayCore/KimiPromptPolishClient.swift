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

    /// Bench fallback when no model is chosen; the app passes the user's
    /// PolishModel (default K3, per the vibe-brief model matrix: best
    /// comprehension at 1× quota, ~8s median).
    public static let model = PolishModel.k3.rawValue

    /// Calibrated via `PressayBench kimi-polish` (the "vibebrief-outcome"
    /// variant): verbatim on fragments; intent, constraints, and negations
    /// survive exactly while structure and wording are freely improved into
    /// an agent brief. `{text}` is replaced with the cleaned transcript.
    public static let defaultTemplate = """
    You turn raw voice dictation into the best possible brief for an AI coding agent (vibe coding). The speaker's intent must survive exactly; the wording is yours to improve.

    Rules:
    - Write in the speaker's first-person voice, as a prompt they will paste to their agent.
    - Order it like a work order: the direct instruction or question first, then the goal or motivation if they gave one, then constraints and boundaries, then how they want the result reported or verified.
    - Keep every constraint, negation, number, URL, name, and technical identifier exactly as dictated. Never invent requirements, technical details, or acceptance criteria they did not give or clearly imply.
    - You may make a clearly implied deliverable explicit (e.g. "take a look and let me know" becomes "investigate and report your findings").
    - Merge redundant restatements; keep the brief as short as clarity allows.
    - Use short bullets when they gave multiple parts, plain prose otherwise.
    - Never add personas, step-by-step reasoning instructions, or formatting they did not ask for.
    - If the dictation is a lone term or fragment with no discernible request, return it verbatim.
    - Do not answer the prompt. Output only the brief, with no commentary.
    - Prefer stating the desired outcome over prescribing the speaker's micro-steps, unless they demanded an explicit order.

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
        timeout: TimeInterval = 45,
        reasoning: KimiReasoning = .standard
    ) async throws -> String {
        let content = try await KimiChatAPI.complete(
            model: model,
            prompt: template.replacingOccurrences(of: "{text}", with: text),
            apiKey: apiKey,
            timeout: timeout,
            reasoning: reasoning
        )
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishError.emptyResult }
        return trimmed
    }
}
