public import LexiconDomain

/// The rules-only cleanup: model text -> text Lexicon can type with no LLM.
/// Pure and deterministic, ~30 µs (#11). It runs on every Dictation alongside
/// AI cleanup and is what gets typed when AI cleanup is off, rejected by the
/// structural check, late, or unavailable (`CleanupSession.finish`).
///
/// Order of the rules-only pass, fixed here and nowhere else:
///   1. filler pass (hard fillers, accidental repeats, comma-bounded soft fillers)
///   2. `verify`: keep step 1 only if it equals the model text minus listed fillers;
///      otherwise fall back to the model text. Rules-only cleanup never changes meaning.
///   3. spoken commands ("new line")
///   4. Rules (the Lexicon's "hear X, write Y")
///   5. light active-app formatting (M5): e.g. no trailing period in a terminal prompt
///   6. punctuation and capital tidy
public enum TextPass {
    public static func run(_ modelText: String, rules: RuleSet, app: AppContext) -> String {
        fatalError("not implemented")
    }
}

/// Filler knowledge. Internal; tested through `TextPass.run` and directly with @testable.
enum Fillers {
    static let hard: Set<String> = ["um", "uh", "er", "erm", "hmm", "mm"]
    static let softWhenCommaBounded: [String] = ["so", "okay", "well", "basically", "you know", "i mean", "like"]

    static func strip(_ text: String) -> (text: String, removed: [String]) { fatalError("not implemented") }
    static func verify(original: String, cleaned: String, removed: [String]) -> Bool { fatalError("not implemented") }
}
