public import LexiconDomain

/// Which app and field had focus, as a comparable value. AppText mints these
/// from Accessibility; the guard only compares them.
public struct FocusSnapshot: Sendable, Hashable {
    public let pid: Int32
    /// Opaque field identity: the receipt's durable fingerprint plus this
    /// element's live identity, so two alike fields in one window differ.
    /// nil when the app exposes no focused element.
    public let fieldFingerprint: String?
    public init(pid: Int32, fieldFingerprint: String?) {
        self.pid = pid
        self.fieldFingerprint = fieldFingerprint
    }
}

public enum InsertDecision: Sendable, Hashable {
    case insert
    case hold(NotInsertedReason)
}

/// The late-text rule (#4), the single home of it: insert only if Jake is still
/// in the same app and field he was in at fn-up and has not typed or clicked
/// since the mark. Applied to EVERY insert, fast or late: there is no grace
/// window, so a quick cloud final after an app switch can never land in the
/// wrong app. Every `TextDestination.insert` calls this first.
///
/// Pure: unit-tested from values, no Accessibility.
public enum InsertGuard {
    /// - target: the focus captured at fn-up (inside the destination's `Target`).
    /// - focusNow: the focus right before the paste; nil when nothing can take text.
    /// - inputSinceMark: `InputClock.hasInput(since: target's mark)`.
    public static func decide(target: FocusSnapshot, focusNow: FocusSnapshot?, inputSinceMark: Bool) -> InsertDecision {
        guard let focusNow else { return .hold(.noField) }
        if focusNow != target { return .hold(.focusMoved) }
        if inputSinceMark { return .hold(.typedSince) }
        return .insert
    }
}
