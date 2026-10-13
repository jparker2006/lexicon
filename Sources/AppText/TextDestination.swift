public import LexiconDomain

/// Where a Dictation's text goes. The Conductor is generic over this, so the
/// eval CLI and tests run the identical lifecycle with a destination that
/// records text instead of pasting it.
///
/// `Target` is captured at stop (fn-up) and is the only thing `insert` accepts.
/// Each destination's `Target` has no public initializer, so code that never
/// captured one (crash recovery, manual retry) cannot type text. That is how
/// "recovered text is never typed" is enforced by the compiler.
public protocol TextDestination: Sendable {
    associatedtype Target: Sendable

    /// fn-down: frontmost app and window, for Lexicon term selection. No screenshots (D5).
    func context() async -> AppContext

    /// The frontmost app now, then each app that comes to the front. While a
    /// Dictation is in flight the Conductor revokes its `CloudAccess` the moment
    /// focus moves into an always-private app (#5).
    func appChanges() async -> AsyncStream<AppContext>

    /// At stop: the focused field plus an input mark. nil when nothing can take text.
    func target() async -> Target?

    /// Asks `InsertGuard.decide` first (#4 late-text rule: same app and field, or
    /// same app under 5 s where no field shows; nothing typed since the mark;
    /// every insert, no grace window), then pastes.
    /// Returns `.inserted(receipt)` or `.notInserted(reason)`; never `.historyOnly`.
    func insert(_ text: String, for id: DictationID, at target: Target) async -> Delivery

    /// ⌃⌘V: the same insert, except that Jake asked for it, so it still pastes
    /// when Lexicon can't save his clipboard (`TargetApp`, without the restore).
    func pasteLast(_ text: String, for id: DictationID, at target: Target) async -> Delivery

    /// Re-speak: the target's field, read now. nil when it is gone or unreadable.
    func read(at target: Target) async -> FieldText?

    /// Re-speak: pastes `text` over `span` of the target's field through the
    /// same paste-and-restore path and late-text guard as an insert, only while
    /// the span still reads `expected`. Taking the Re-speak's own live `Target`
    /// is what keeps a recovered or retried Re-speak from editing any app.
    func replace(_ span: TextSpan, expected: String, with text: String, at target: Target) async -> ReplaceOutcome
}

extension TextDestination {
    public func pasteLast(_ text: String, for id: DictationID, at target: Target) async -> Delivery {
        await insert(text, for: id, at: target)
    }

    /// A destination with no field to read has nothing to replace.
    public func read(at target: Target) async -> FieldText? { nil }

    public func replace(_ span: TextSpan, expected: String, with text: String, at target: Target) async -> ReplaceOutcome {
        .refused(.noField)
    }
}
