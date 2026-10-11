import LexiconDomain

/// Splits text into finished sentences and an unfinished tail. Pure.
/// A sentence ends at . ? ! followed by a space or the end of finalized text;
/// "e.g.", decimals ("3.5") and version strings ("v1.2") do not end one.
enum Sentences {
    static func split(_ text: String) -> (finished: [String], tail: String) {
        fatalError("not implemented")
    }
}

/// Is the LLM's text the same speech, only tidied? Pure, microseconds, and the
/// only thing standing between an LLM and Jake's cursor. Checked against the
/// Rules-applied text (`ruled`), never the raw model text, so a Rule's output
/// counts as spoken.
///
/// Passes when all hold:
///   - every content word of `ruled` is still there (fillers, self-repair words
///     and accidental repeats may go: `Fillers`)
///   - no added words, except list markers ("1.", "-", "•") and Lexicon `terms`
///   - every digit run matches a number that was spoken (as digits or words)
///   - length at most `lengthCap` × the ruled length
///   - no code block (``` or 4-space indent) unless code was spoken
enum StructuralCheck {
    static let lengthCap = 1.3

    /// nil = accept. Otherwise the first failure found.
    static func check(_ candidate: String, ruled: String, terms: [Term]) -> CheckFailure? {
        fatalError("not implemented")
    }
}
