public import LexiconDomain
public import WordStore
public import Jev

/// What a Re-speak should replace, before anything is replaced (#83 replaces,
/// #85 shows the choices and the no-match notice).
public enum RespeakResolution: Sendable, Hashable {
    /// Sure enough to replace this span at once.
    case pick(SpanCandidate)
    /// Unsure: the top 2 or 3 spans, most likely first. Jake picks with 1, 2 or 3; Esc leaves it.
    case choices([SpanCandidate])
    /// Nothing in the recent text is what Jake said again: change nothing and say so.
    case noMatch
}

/// Finds the span a Re-speak replaces: the candidate finder ranks the recent
/// text by sound, Jev chooses among the best few, and when Jev can't answer
/// (Private mode, no key, past its budget) the sound ranking decides alone.
public struct RespeakResolver: Sendable {
    /// Jev's top probability at or over this replaces at once; under it, Jake
    /// chooses. A starting value from the spec, to be tuned on the Test set.
    public static let sureAt = 0.75

    let jev: JevClient

    public init(jev: JevClient) { self.jev = jev }

    /// `spoken`: the Re-speak's cleaned text. `recent`: the text before the
    /// caret, in practice the last Dictation.
    public func resolve(_ spoken: String, recent: String, access: CloudAccess?) async -> RespeakResolution {
        .noMatch
    }
}
