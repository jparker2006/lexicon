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
        // them stay ("teh," -> "the,"), and Cleanup's sentence marks go.
        let lead = String(before.prefix(while: isEdge))
        let trail = String(before.dropFirst(lead.count).reversed().prefix(while: isEdge).reversed())
        let selected = before.dropFirst(lead.count).dropLast(trail.count)
        var text = words(of: spoken)
        guard !text.isEmpty else { return "" }
        // Mid-sentence, a plain English word loses the sentence's capital. "I", a
        // name, a Term, or a word like GitHub keeps its form (DECISIONS.md item 85).
        let word = firstWord(text)
        if let first = text.first, selected.first?.isLowercase == true, word != "I", !word.hasPrefix("I'"),
           !terms.contains(where: { firstWord(words(of: $0)) == word }),
           !word.dropFirst().contains(where: \.isUppercase), isEnglish(word.lowercased()) {
            text = first.lowercased() + text.dropFirst()
        }
        return lead + text + trail
    }

    /// The first word of what Jake said, without the marks around it: the word
    /// whose plainness `isEnglish` is asked about. "Dog, then." -> "Dog".
    public static func firstWord(_ spoken: String) -> String {
        let text = words(of: spoken)
        return String(text.prefix { !$0.isWhitespace }.reversed().drop(while: isEdge).reversed())
    }

    /// The text without the spaces and punctuation at its edges.
    private static func words(of text: String) -> String {
        String(text.drop(while: isEdge).reversed().drop(while: isEdge).reversed())
    }

    private static func isEdge(_ character: Character) -> Bool { character.isWhitespace || character.isPunctuation }
}
