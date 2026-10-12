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
    /// chooses. The spec's starting value, to be tuned on the Test set.
    public static let sureAt = 0.75
    /// By sound alone, a best span further than this from what Jake said is no
    /// match: Private mode changes nothing rather than replace a word that
    /// merely shares a sound. A starting value: on the synthesized cases every
    /// right span scored 0.48 or less, and every word with no match had no
    /// span under 0.54. To be tuned on the Test set with `sureAt`.
    public static let soundCutoff = 0.5
    /// The most choices Jake gets, one per key 1, 2 and 3.
    static let mostChoices = 3

    let jev: JevClient

    public init(jev: JevClient) { self.jev = jev }

    /// `spoken`: the Re-speak's cleaned text. `recent`: the text before the
    /// caret, in practice the last Dictation.
    public func resolve(_ spoken: String, recent: String, access: CloudAccess?) async -> RespeakResolution {
        let ranked = CandidateFinder.candidates(for: spoken, in: recent)
        let bySound: RespeakResolution = if let best = ranked.first, best.distance <= Self.soundCutoff {
            .pick(best)
        } else {
            .noMatch
        }
        guard let question = JevQuestion.respeakTarget(
            spoken: spoken, spokenPhonetic: Phonetic.code(spoken), recent: recent,
            candidates: ranked.map { RespeakCandidate(words: $0.words, phonetic: $0.phonetic) })
        else { return bySound }

        let decision = await jev.decide(question, access: access, fallback: [])
        guard case .jev = decision.source, let top = decision.answer.first else { return bySound }
        // Jev's best guess is that Jake corrected none of them: never replace on a lesser one.
        guard let best = top.candidate else { return .noMatch }
        if top.probability >= Self.sureAt { return .pick(ranked[best]) }
        return .choices(decision.answer.compactMap(\.candidate).prefix(Self.mostChoices).map { ranked[$0] })
    }
}
