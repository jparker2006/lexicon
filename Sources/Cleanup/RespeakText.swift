import Foundation

/// The words a Re-speak puts over the words it fixes. Cleanup writes a
/// Re-speak as a sentence ("Dog."), and Cleanup owns how text is cased and
/// stopped, so fitting it into the middle of Jake's text lives here too. Pure.
public enum RespeakText {
    /// `spoken`: the Re-speak's cleaned text. `before`: the words it replaces.
    /// `terms`: the Lexicon's written forms. `isEnglish`: whether a word is plain
    /// English and never a name (WordStore's `PlainEnglish`).
    public static func replacement(_ spoken: String, replacing before: String, terms: Set<String>,
                                   isEnglish: (String) -> Bool = { _ in true }) -> String {
        // A selection that took the space next to a word keeps it, so words never run together.
        let lead = before.prefix(while: \.isWhitespace), trail = String(before.reversed().prefix(while: \.isWhitespace).reversed())
        let selected = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cleanup ends a sentence with a stop; the selected words keep their own, or none.
        if let last = text.last, ".!?".contains(last) { text.removeLast() }
        guard !text.isEmpty else { return "" }
        let stop = selected.last.map { ".!?".contains($0) ? String($0) : "" } ?? ""
        // Mid-sentence, a plain English word loses the sentence's capital. "I", a
        // name, a Term, or a word like GitHub keeps its form (DECISIONS.md item 85).
        // The first word without the mark after it: "Dog," is the word "Dog".
        let word = String(text.prefix { !$0.isWhitespace }.reversed().drop { $0.isPunctuation }.reversed())
        if let first = text.first, selected.first?.isLowercase == true, word != "I", !word.hasPrefix("I'"),
           !terms.contains(where: { $0.prefix { !$0.isWhitespace } == word }),
           !word.dropFirst().contains(where: \.isUppercase), isEnglish(word.lowercased()) {
            text = first.lowercased() + text.dropFirst()
        }
        return lead + text + stop + trail
    }
}
