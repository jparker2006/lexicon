import Foundation
public import LexiconDomain
public import KeyInput

/// Everything Lexicon does to text inside other apps: insert, find again, read,
/// watch, replace (#7, #13).
///
/// Hides: the paste path (pasteboard promise, the target's read as a receipt,
/// restore after 200 ms of no reads guarded by `changeCount`, 8 s cap,
/// transient/concealed pasteboard markers, the physical key for "v" on the
/// current layout), focus checks, AX messaging timeouts (100-200 ms), turning
/// on Electron/Chromium accessibility only during a watch window and restoring
/// it, re-looking-up elements, secure-field skipping, and the per-terminal
/// replace strategies (Terminal.app arrows + Backspace, iTerm2 select-then-
/// replace, Ghostty only when nothing was typed since).
///
/// AX element references never leave this actor. Callers name text by
/// `DictationID`; this actor remembers where each recent Dictation landed (in
/// memory). The durable key is the `InsertionReceipt` that `insert` returns,
/// which History stores; `reattach` re-finds a field from it after a restart.
///
/// Runs on its own thread with a run loop (AX observers need one, and a hung
/// target app must stall this thread, never the main thread or the Conductor).
public actor TargetApp: TextDestination {
    let executor: RunLoopExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    public init(input: InputClock) { fatalError("not implemented") }

    /// Opaque, minted only here, only from the live focus at stop time.
    public struct Target: Sendable {
        let focus: FocusSnapshot
        let bundleID: String?
        let mark: InputMark
        let capturedAt: HostTime
    }

    public func context() -> AppContext { fatalError("not implemented") }
    public func target() -> Target? { fatalError("not implemented") }

    public func insert(_ text: String, for id: DictationID, at target: Target) async -> Delivery {
        // TODO: switch InsertGuard.decide(target: target.focus, focusNow: currentFocus(),
        //                                 inputSinceMark: input.hasInput(since: target.mark)) {
        //   case .hold(let reason): return .notInserted(reason)
        //   case .insert: write the promise, post Cmd-V (our pid); no receipt read -> .notInserted(.pasteFailed)
        // }
        // Remember the live placement for `id` (AX element, range before the caret: memory only),
        // then read caret and ~40 chars each side once and return
        // .inserted(InsertionReceipt(appBundleID:, fieldFingerprint:, caretAfter:, contextBefore:,
        //           contextAfter:, insertedAt: Date())). Schedule the clipboard restore.
        fatalError("not implemented")
    }

    /// After a restart (no live placement for `id`): find the field again from
    /// the durable receipt History kept (fingerprint, then context around the
    /// caret). True when the placement is live again for read/watch/replace.
    public func reattach(_ id: DictationID, receipt: InsertionReceipt) -> Bool { fatalError("not implemented") }

    // MARK: Finding text again (Fixes)

    /// The field a recent Dictation landed in, read now. nil if gone or unreadable.
    public func read(_ id: DictationID) -> FieldText? { fatalError("not implemented") }

    /// Value and focus changes of that field for `window` (Hand fix watch: #13).
    /// Ends early when focus leaves or the field clears; yields the last
    /// non-empty value seen before that.
    public func watch(_ id: DictationID, for window: Duration) -> AsyncStream<FieldText> {
        fatalError("not implemented")
    }

    /// Replaces a span of a recent Dictation's text (Re-speak fix, close calls).
    /// Picks the strategy for the target app; refuses (false) when it cannot be
    /// done safely (Claude Code collapsed paste, Ghostty after typing).
    public func replace(_ span: TextSpan, in id: DictationID, with text: String) async -> Bool {
        fatalError("not implemented")
    }

    /// "I just fixed this": the focused field (or its selection) right now.
    public func readFocused() -> FieldText? { fatalError("not implemented") }
}

/// Text read from another app's field. Offsets are UTF-16, like AX.
public struct FieldText: Sendable, Hashable {
    public let text: String
    public let selection: TextSpan?
    /// Where the Dictation's text sits now, if it can still be located.
    public let dictationSpan: TextSpan?
    public let app: AppContext
}

public struct TextSpan: Sendable, Hashable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}
