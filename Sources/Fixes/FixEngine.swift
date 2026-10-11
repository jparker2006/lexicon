import Foundation
public import LexiconDomain
public import History
public import WordStore
public import AppText
public import Jev

/// How Lexicon asks "always fix it this way?" (#24 decides toast vs review list
/// vs question). The UI implements it; Fixes never imports AppKit.
public protocol FixPrompter: Sendable {
    func propose(_ proposal: RuleProposal) async -> RuleAnswer
}

public struct RuleProposal: Sendable, Hashable {
    public let fix: Fix
    public let rule: Rule
}

public enum RuleAnswer: Sendable, Hashable {
    case always
    case notThisTime
    case never
}

public enum RespeakOutcome: Sendable, Hashable {
    case replaced(Fix)
    case nothingToReplace
    /// The text can't be reached safely (collapsed paste, Ghostty after typing, field gone).
    case unreachable(String)
}

/// Finds Fixes and turns confirmed ones into Rules (M4, M5).
///
/// Hides: the Hand fix watch window after each insert (AX via AppText, last
/// non-empty value, diff when focus leaves / field clears / next Dictation /
/// 60 s), matching a Claude Code or Codex hook prompt to the Dictation it
/// contains, the "I just fixed this" read, diffing, size filters, the Jev
/// recognition-error check with a local fallback, close-call checks after
/// insert, Re-speak span resolution (Lexicon phonetics + Jev) and replacement.
///
/// Writes Fixes only through `HistoryStore.record(.fixRecorded)` and Rules only
/// through `Lexicon.add`. Owns nothing durable itself; its only state is the
/// in-memory watch windows.
public actor FixEngine {
    public init(history: HistoryStore, lexicon: Lexicon, text: TargetApp, jev: JevClient, prompter: any FixPrompter) {
        fatalError("not implemented")
    }

    /// Called by the Conductor after a live insert. Returns at once; the watch
    /// window and the close-call check (#10) run in their own tasks. `receipt` is
    /// what History keeps; later matching (hook prompts, Re-speak after a restart)
    /// starts from `history.receipt(for:)` and `TargetApp.reattach`.
    public func didInsert(_ id: DictationID, text: String, app: AppContext, receipt: InsertionReceipt,
                          access: CloudAccess?) {
        fatalError("not implemented")
    }

    /// A new Dictation started: close any open watch window now (one of #13's diff triggers).
    public func dictationStarted() { fatalError("not implemented") }

    /// From the inbox. Finds the recent terminal Dictation this prompt contains,
    /// diffs, records. Idempotent: the same prompt twice records one Fix (FixID
    /// derived from dictation id + text hash).
    public func promptSubmitted(_ prompt: SubmittedPrompt) async { fatalError("not implemented") }

    /// "I just fixed this" shortcut.
    public func justFixed(access: CloudAccess?) async { fatalError("not implemented") }

    /// M4: `spoken` is the Re-speak Dictation's cleaned text; `target` the Dictation to fix.
    public func respeak(_ spoken: String, fixing target: DictationID, access: CloudAccess?) async -> RespeakOutcome {
        fatalError("not implemented")
    }
}

/// Word-level diff of a Dictation's text against what the field holds now. Pure.
enum WordDiff {
    struct Change: Sendable, Hashable {
        let before: String
        let after: String
    }
    static func changes(from before: String, to after: String) -> [Change] { fatalError("not implemented") }

    /// #13 filters: an edit that changes most of the text is a rewrite, not a Fix candidate.
    static func looksLikeRewrite(_ changes: [Change], originalWordCount: Int) -> Bool { fatalError("not implemented") }
}
