public import Foundation
public import LexiconDomain

// The inbox is how short-lived processes talk to the running app: a directory
// of JSON files. A writer posts one file per message (write temp, then rename:
// atomic); the app watches the directory, reads each file, deletes it. The
// `lexicon` hook CLI that would write them is not built before the after-M1 grill.
//
// Why a directory and not a socket: no listener thread in the app, nothing to
// lose when the app is not running (files wait for the next launch), and file
// permissions are the whole security story. Delivery is at most once (deleted
// after it is handed on); every consumer is idempotent anyway.

/// Every message the app accepts from outside. The ONE list: the app's router is
/// an exhaustive switch over it.
public enum InboxMessage: Sendable, Codable, Hashable {
    /// Claude Code / Codex UserPromptSubmit hook: the exact prompt Jake sent (#13).
    case promptSubmitted(SubmittedPrompt)
    /// Dev test hook (#14): "dictate this WAV" through the full live path,
    /// typing into whatever field has focus. Ignored unless test hooks are on.
    case dictateFile(path: String)
}

/// For a short-lived writer process. Foundation only, starts in milliseconds.
public struct InboxWriter: Sendable {
    /// `<root>/inbox/` (this module names it).
    public init(paths: AppPaths) { fatalError("not implemented") }

    /// Encodes, writes `inbox/.tmp-<uuid>`, renames to `inbox/<time>-<uuid>.json`.
    public func post(_ message: InboxMessage) throws {
        fatalError("not implemented")
    }
}

/// Used by the app. Scans once at start (messages left while it was not
/// running), then reacts to directory changes (DispatchSource vnode write events).
public final class InboxWatcher: Sendable {
    /// Hook prompts older than this when drained are dropped, not delivered: they
    /// waited while the app was off, and Hand fix matching only pairs a prompt with
    /// a Dictation inserted moments before (#13's watch window is 60 s).
    static let promptMaxAge: Duration = .seconds(60)

    public init(paths: AppPaths) { fatalError("not implemented") }

    /// Oldest first. Malformed files are moved to `inbox/bad/` and logged, never retried.
    public var messages: AsyncStream<InboxMessage> { fatalError("not implemented") }
}

extension SubmittedPrompt {
    /// Parses the JSON Claude Code (or Codex) writes to a hook's stdin. Wire
    /// knowledge stays in this module; everyone else sees `SubmittedPrompt`.
    public static func fromHookInput(_ data: Data, source: SubmittedPrompt.Source, now: Date) throws -> SubmittedPrompt {
        // TODO: decode { "prompt": ..., "cwd": ..., "session_id": ..., "hook_event_name": "UserPromptSubmit" }.
        fatalError("not implemented")
    }
}
