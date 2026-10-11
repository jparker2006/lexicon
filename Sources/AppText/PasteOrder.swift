import LexiconDomain

/// Where Cmd-V goes out: one at a time, so a queued Cmd-V never pastes a later
/// Dictation's text. `Paster` is the real one; tests use a fake.
/// A Dictation typed at fn-up, or ⌃⌘V, which Jake asked for.
enum PasteKind: Sendable { case dictation, pasteLast }

protocol PasteLane: Sendable {
    /// Returns once no earlier paste is unread.
    func idle() async
    /// Puts the text up and sends Cmd-V now, without waiting.
    func paste(_ text: String, as kind: PasteKind) async -> PasteAttempt
}

enum PasteAttempt: Equatable {
    case sent(ClipboardKeeper.PasteID)
    /// Another paste went first since `idle`: wait and check again.
    case busy
    /// No Cmd-V key or event could be made.
    case failed
    /// Lexicon may not read the clipboard, so it could never put Jake's back.
    case denied
}

enum PasteOrder {
    enum Result<Seen> {
        /// `seen`: what the check looked at, for the receipt.
        case sent(ClipboardKeeper.PasteID, checkedAt: ContinuousClock.Instant, seen: Seen)
        case held(NotInsertedReason)
        case failed
    }

    /// Waits out an earlier unread paste first (up to 2 s after it missed), and only
    /// then runs the late-text `check`: a check made before that wait would be
    /// stale by the time Cmd-V goes out, and Jake may have moved to another app.
    /// Nothing waits between the check and the key; another paste that went
    /// first meanwhile sends this one back to wait and check again.
    static func run<Seen>(_ text: String, as kind: PasteKind, lane: some PasteLane, isolation: isolated (any Actor)? = #isolation,
                          check: () -> (InsertDecision, Seen)) async -> Result<Seen> {
        while true {
            await lane.idle()
            let checkedAt = ContinuousClock.now
            let (decision, seen) = check()
            if case .hold(let reason) = decision { return .held(reason) }
            switch await lane.paste(text, as: kind) {
            case .sent(let id): return .sent(id, checkedAt: checkedAt, seen: seen)
            case .busy: continue
            case .failed: return .failed
            case .denied: return .held(.clipboardDenied)
            }
        }
    }
}

extension PasteOrder.Result: Sendable where Seen: Sendable {}
