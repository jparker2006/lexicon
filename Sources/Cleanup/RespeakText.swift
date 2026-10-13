import Foundation

/// The words a Re-speak puts over the words it fixes. Cleanup writes a
/// Re-speak as a sentence ("Dog."), and Cleanup owns how text is cased and
/// stopped, so fitting it into the middle of Jake's text lives here too. Pure.
public enum RespeakText {
    /// `spoken`: the Re-speak's cleaned text. `before`: the words it replaces.
    /// `terms`: the Lexicon's written forms. `isEnglish`: whether the first word
    /// is plain English and never a name (WordStore's `PlainEnglish`).
    public static func replacement(_ spoken: String, replacing before: String, terms: Set<String>,
                                   isEnglish: (String) -> Bool = { _ in true }) -> String {
        // Only the words change: the selection's own spaces and punctuation around
        // them stay ("teh," -> "the,"), and the one stop Cleanup closed it with goes.
        let lead = String(before.prefix(while: opens))
        let trail = String(before.dropFirst(lead.count).reversed().prefix(while: closes).reversed())
        let selected = before.dropFirst(lead.count).dropLast(trail.count)
        var text = sentence(spoken, isEnglish: isEnglish)
        guard text.contains(where: { !$0.isPunctuation }) else { return "" }
        // Mid-sentence, a plain English word loses the sentence's capital. "I", a
        // name, a Term, or a word like GitHub keeps its form (DECISIONS.md item 85).
        let word = firstWord(text)
        if let first = text.first, selected.first?.isLowercase == true, word != "I", !word.hasPrefix("I'"),
           !terms.contains(where: { firstWord($0) == word }),
           !word.dropFirst().contains(where: \.isUppercase), isEnglish(word.lowercased()) {
            text = first.lowercased() + text.dropFirst()
        }
        return lead + text + trail
    }

    /// The words, lowercased, whose plainness `replacement` may ask about: the first
    /// word, and the last when a period follows it. Look them up before calling it.
    public static func plainnessQuestions(_ spoken: String) -> Set<String> {
        var words: Set<String> = [firstWord(spoken).lowercased()]
        if let last = abbreviation(closing: spoken.trimmingCharacters(in: .whitespacesAndNewlines)) { words.insert(last) }
        return words
    }

    /// The last word, lowercased, when a period closes it and Cleanup lists it as
    /// an abbreviation ("etc.", "e.g.", but also "no." and "min."): whether that
    /// period is the word's own or Cleanup's stop is then a question.
    private static func abbreviation(closing text: String) -> String? {
        guard text.hasSuffix("."), !text.hasSuffix(".."),
              let last = text.split(whereSeparator: \.isWhitespace).last else { return nil }
        let word = last.dropLast().lowercased()
        return Fillers.abbreviations.contains(word) ? word : nil
    }

    /// The first word of what Jake said, without the marks around it: the word
    /// whose plainness `isEnglish` is asked about. "Dog, then." -> "Dog".
    public static func firstWord(_ spoken: String) -> String {
        let text = words(of: spoken)
        return String(text.prefix { !$0.isWhitespace }.reversed().drop(while: isEdge).reversed())
    }

    /// What Jake said without the stop Cleanup ends a sentence with: "C#." is
    /// "C#"; a mark that is part of his words (#, %, a leading dot), a comma or
    /// colon he said, a run of dots and an abbreviation's period stay.
    private static func sentence(_ spoken: String, isEnglish: (String) -> Bool) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        // A run of dots ("..", "...") is Jake's own mark, and a true abbreviation's
        // period ("etc.", "e.g.") is part of the word: neither is a stop Cleanup
        // added. A listed abbreviation that is a plain word ("no.") is his word and Cleanup's stop.
        let ownPeriod = abbreviation(closing: text).map { $0.contains(".") || !isEnglish($0) } ?? false
        if let last = text.last, ".!?".contains(last), !text.hasSuffix(".."), !ownPeriod {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What surrounds a selected word rather than belonging to it: spaces, quotes
    /// and brackets before it; spaces, quotes, brackets and clause marks after it.
    /// A word's own marks (C#, 100%, .NET) are replaced with the word.
    private static func opens(_ character: Character) -> Bool {
        character.isWhitespace || "\"'\u{201C}\u{2018}([{\u{00AB}".contains(character)
    }

    private static func closes(_ character: Character) -> Bool {
        character.isWhitespace || "\"'\u{201D}\u{2019})]}\u{00BB}.,;:!?\u{2026}".contains(character)
    }

    /// The text without the spaces and punctuation at its edges.
    private static func words(of text: String) -> String {
        String(text.drop(while: isEdge).reversed().drop(while: isEdge).reversed())
    }

    private static func isEdge(_ character: Character) -> Bool { character.isWhitespace || character.isPunctuation }
}
