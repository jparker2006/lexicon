import Foundation

// Cleanup's results as other modules see them. They live here because History
// stores them (`.textReady` records the outcome, the window shows "cleanup
// rejected") and History may not depend on Cleanup.

/// Hosted models AI cleanup may call through OpenRouter (#20). THE list: the
/// settings picker and the stored outcome derive from it. The exact model and
/// the pinned fast providers are the cleanup bake-off's call.
public enum CloudCleanupModel: String, Sendable, Codable, CaseIterable {
    case openRouterFast = "openrouter.fast"

    public var displayName: String {
        switch self {
        case .openRouterFast: "Fast hosted model (OpenRouter)"
        }
    }
}

/// Which model cleaned a Dictation's text when AI cleanup was accepted. Hosted
/// only: no on-device model qualifies, so Private mode and offline are rules only.
/// An enum, not a bare `CloudCleanupModel`, because History stores this shape.
public enum CleanupEngine: Sendable, Hashable, Codable {
    case cloud(CloudCleanupModel)
}

/// What the cleanup stage did for one Dictation. Recorded by History on `.textReady`.
public enum CleanupOutcome: Sendable, Hashable, Codable {
    /// The LLM's text passed the structural check and was typed.
    case aiAccepted(CleanupEngine)
    /// The rules-only cleanup was typed instead.
    case rulesOnly(RulesOnlyReason)
}

public enum RulesOnlyReason: Sendable, Hashable, Codable {
    /// The "AI cleanup" toggle is off: nothing left the Mac for cleanup.
    case off
    /// The LLM answered but failed the structural check. History shows "cleanup rejected".
    case rejected(CheckFailure)
    /// The LLM missed `Preferences.cleanupDeadline` after the speech final.
    case deadline
    /// No model could run (no key, network error).
    case unavailable
}

/// Why the structural check rejected an LLM's text. Checked against the
/// Rules-applied text, never against the LLM's own idea of what was said.
public enum CheckFailure: String, Sendable, Hashable, Codable, CaseIterable {
    /// A content word that was spoken is missing.
    case droppedContentWord
    /// A word appeared that was not spoken and is neither a list marker nor a Lexicon term.
    case addedWord
    /// Digits that do not match the spoken numbers.
    case numberMismatch
    /// Output longer than the length cap allows.
    case tooLong
    /// A code block (``` or indented block) nobody spoke.
    case unspokenCode
}
