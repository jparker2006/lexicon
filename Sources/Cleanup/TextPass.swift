public import LexiconDomain

/// The rules-only Cleanup: model text -> text Lexicon can type with no LLM.
/// Pure and deterministic, microseconds. It runs on every Dictation in every
/// mode. M0 to M2 type it; from M3 it is what gets typed when AI cleanup is
/// off, rejected by the structural check, late, or unavailable
/// (`CleanupSession.finish`).
///
/// Order, fixed here and nowhere else:
///   1. Rules and Term folding (`RuleSet.apply`)
///   2. the filler pass, one line at a time (`Fillers.clean`), which never
///      deletes a Term or a Rule's written side, or changes its case
///
/// The speech model already supplies punctuation and capitals. The pass only
/// deletes listed fillers and accidental repeats, then tidies the spacing,
/// commas and sentence capitals its deletions disturb. It never deletes a
/// hedge, negation or constraint (`Fillers.protected`).
public enum TextPass {
    public static func run(_ modelText: String, rules: RuleSet) -> String {
        let ruled = rules.isEmpty ? modelText : rules.apply(to: modelText)
        var dictationStart = true
        return ruled.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { line in
                let cleaned = Fillers.clean(line, dictationStart: dictationStart, rules: rules)
                if !cleaned.isEmpty { dictationStart = false }
                return cleaned
            }
            .joined(separator: "\n")
    }
}

/// Filler knowledge and the filler pass. Internal; tested through `TextPass.run`.
///
/// What goes, and when (cases: docs/research/cleanup-pass.md on branch
/// `research/cleanup-pass`):
///   - hard fillers ("um", "uh"), anywhere
///   - hard fillers inside an interjection ("uh huh", "uh oh", "mm hmm") stay
///   - an immediate repeat of the word before ("the the"), unless the double can
///     be meant ("that that", "had had", "not not") or is a number ("twenty
///     twenty six", "ten ten", "five five five")
///   - "like" and "you know" only when set off on both sides: a comma or the
///     start of a sentence before, a comma after. "like" stays before a
///     comparison, an estimate or a name ("like, the primary color", "like,
///     eighty seconds", "like, Postgres").
///   - "so", "okay", "well", "basically" and "I mean" only at the start of the
///     Dictation, before anything is kept. Later in a Dictation they can carry
///     meaning: a result ("So we can see it"), a self-correction ("Delete it.
///     I mean, rename it"). "so" stays when it starts a phrase ("so that",
///     "so far"); "okay", "well" and "I mean" need a comma after ("okay" may
///     run into "so" or "um"); "basically" goes only after another opener
///     ("Okay, so basically, ..."), since alone it hedges.
enum Fillers {
    static let hard: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hm", "hmm", "hmmm"]

    /// After a sentence-start "so", these make it part of the meaning.
    static let soPhrases: Set<String> = [
        "that", "far", "much", "many", "few", "little", "long", "what", "too", "as", "on", "forth", "called",
        "such", "very",
    ]

    /// After "like", these make it a comparison or an estimate, not a filler.
    /// So does a number, a word with a digit ("like, 5 MB", "like, $5") or a name.
    static let likeKeepers: Set<String> = [
        "the", "my", "your", "his", "her", "its", "our", "their", "this", "that", "these", "those", "in", "on", "at",
        "to", "of", "for", "with", "from", "than", "as", "a", "an", "half", "few", "couple", "several", "some",
        "many", "most", "about", "around", "maybe", "under", "over", "almost", "nearly", "roughly", "twice",
        "double", "triple", "hundreds", "dozens", "thousands", "millions", "billions", "lots", "more", "less",
        "between", "upwards", "somewhere",
    ]

    /// Two-word interjections made of filler sounds: answers and exclamations, never fillers.
    /// Only without a comma between: "uh, huh?" is a filler and then "huh". "uh uh" and
    /// "um hmm" are left out: written that way they are as likely two fillers as a word.
    static let interjections: Set<String> = ["uh huh", "uh oh", "mm hmm", "ah ha"]

    /// Hedges, negations and constraints. Never deleted, not even as a repeat
    /// ("it's not not working" means it works).
    static let protected: Set<String> = [
        "not", "no", "never", "don't", "doesn't", "didn't", "won't", "can't", "cannot", "isn't", "aren't", "wasn't",
        "weren't", "shouldn't", "wouldn't", "couldn't", "nothing", "none", "nor", "without", "only", "just", "except",
        "unless", "but", "think", "maybe", "probably", "perhaps", "might", "guess", "kind", "sort", "actually",
        "really", "always", "must", "should", "all", "every", "exactly", "least", "most", "few", "any", "ever",
        "almost", "nearly", "roughly", "hardly", "barely", "neither", "nobody", "instead", "rather", "until",
        "before", "after", "if", "dont", "doesnt", "cant", "wont", "ain't", "kinda", "sorta", "nah", "nope",
    ]

    /// Doubles that grammar allows, on top of `protected`.
    static let meantDoubles: Set<String> = [
        "that", "had", "is", "do", "so", "very", "bye", "ha", "knock", "much", "long", "far", "way", "super", "many",
        "more", "well", "too", "pretty", "totally",
    ]

    /// Words that cannot end a clause: "and, um, open" becomes "and open", not "and, open".
    static let glue: Set<String> = [
        "and", "but", "or", "so", "to", "you", "it's", "is", "the", "a", "an", "of", "for", "that", "i", "we", "can",
        "just", "if", "because", "like",
    ]

    /// Tokens ending in "." that need not end a sentence (`Fillers.clean` decides).
    static let abbreviations: Set<String> = [
        "e.g", "i.e", "vs", "mr", "mrs", "ms", "dr", "jr", "sr", "st", "a.m", "p.m", "u.s", "u.k", "approx", "inc",
        "vol", "fig", "etc", "al", "cf", "ca", "est", "dept", "no", "ft", "lb", "lbs", "oz", "min", "sec", "hr",
        "hrs", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]

    /// Titles: always followed by a name, so the capital after them never starts a sentence.
    /// ("ms" and "st" are left out: "20 ms." and "Main St." often end one.)
    static let titles: Set<String> = ["mr", "mrs", "dr"]

    /// The filler pass over one line. A line always starts a sentence;
    /// `dictationStart`: no earlier line kept anything.
    static func clean(_ line: Substring, dictationStart: Bool, rules: RuleSet) -> String {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(Token.init)
        // The speech model capitalizes after a sentence end, so "etc. Um, ship it"
        // ends a sentence and "etc. um, then ship it" does not.
        for i in tokens.indices.dropLast() where tokens[i].isAbbreviation && !titles.contains(tokens[i].word) {
            tokens[i].endsSentence = tokens[i + 1].isCapitalized
        }
        var kept: [String] = []
        var keptWords: [String] = []
        var sentenceKept = 0          // tokens kept in the current sentence
        var droppedOpener = false     // the current sentence lost its first word(s)
        var setOffBefore = true       // a comma or a sentence start sits just before this token

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil

            if token.isPunctuationOnly {
                if !kept.isEmpty, sentenceKept > 0 || token.endsSentence {
                    kept[kept.count - 1] = Token.merge(kept[kept.count - 1], token.trailing)
                }
                if token.endsSentence { sentenceKept = 0; droppedOpener = false }
                setOffBefore = true
                i += 1
                continue
            }

            // A Term or a Rule's written side is never a filler: "OK" written by a Rule stays.
            let drop = rules.isWritten(token.text) ? 0 : dropCount(token, prior: i > 0 ? tokens[i - 1] : nil, next: next,
                                 after: i + 2 < tokens.count ? tokens[i + 2] : nil,
                                 dictationStart: dictationStart && kept.isEmpty, afterOpener: droppedOpener, setOffBefore: setOffBefore,
                                 previous: sentenceKept > 0 ? (kept.last!, keptWords.last!, sentenceKept == 1) : nil)
            if drop > 0 {
                let last = tokens[i + drop - 1]
                if sentenceKept > 0 {
                    if last.endsSentence {
                        kept[kept.count - 1] = Token.merge(kept[kept.count - 1], last.trailing)
                    } else if last.trailing.contains(","), kept[kept.count - 1].hasSuffix(","),
                              glue.contains(keptWords[keptWords.count - 1]), !keptHedge(kept, keptWords, sentenceKept) {
                        kept[kept.count - 1].removeLast()
                    }
                } else {
                    droppedOpener = true
                }
                if last.endsSentence { sentenceKept = 0; droppedOpener = false }
                setOffBefore = setOffBefore || last.setsOffNext
                i += drop
                continue
            }

            var text = String(token.text)
            if sentenceKept == 0, droppedOpener, !token.isCode, !rules.isWritten(token.text) {
                text = Token.capitalized(text)
            }
            kept.append(text)
            keptWords.append(token.word)
            sentenceKept = token.endsSentence ? 0 : sentenceKept + 1
            droppedOpener = false
            setOffBefore = token.setsOffNext
            i += 1
        }
        // "Add a test, um": the comma went with the filler.
        if tokens.last?.trailing.hasPrefix(",") == false, kept.last?.hasSuffix(",") == true {
            kept[kept.count - 1].removeLast()
        }
        return kept.joined(separator: " ")
    }

    /// The last kept token is a "like" set off on both sides, kept as a hedge
    /// ("takes, like, um, eighty"): its comma stays when a filler after it goes.
    private static func keptHedge(_ kept: [String], _ keptWords: [String], _ sentenceKept: Int) -> Bool {
        keptWords.last == "like" && (sentenceKept == 1 || kept[kept.count - 2].last.map { ",;:".contains($0) } == true)
    }

    /// How many tokens from `token` on are fillers to delete: 0, 1 or 2.
    /// `prior`: the token just before, kept or not.
    /// `previous`: the last kept token in this sentence, its word, and whether it opened the sentence.
    /// `dictationStart`: nothing kept yet in the Dictation. `afterOpener`: a filler already went from this sentence's start.
    private static func dropCount(_ token: Token, prior: Token?, next: Token?, after: Token?, dictationStart: Bool, afterOpener: Bool,
                                  setOffBefore: Bool, previous: (text: String, word: String, opensSentence: Bool)?)
        -> Int {
        let word = token.word
        if protected.contains(word) || token.isQuoted { return 0 }
        if let next, token.trailing.isEmpty, interjections.contains(word + " " + next.word) { return 0 }
        if let prior, prior.trailing.isEmpty, interjections.contains(prior.word + " " + word) { return 0 }
        if hard.contains(word), !token.isAcronym { return 1 }

        if dictationStart, let next, !token.endsSentence {
            let comma = token.trailing.hasPrefix(",")
            switch word {
            case "so": if !soPhrases.contains(next.word) { return 1 }
            case "okay", "ok":
                if comma ? next.word != "or" : next.word == "so" || hard.contains(next.word) { return 1 }
            case "well": if comma { return 1 }
            case "basically": if comma, afterOpener { return 1 }
            case "i": if token.trailing.isEmpty, next.word == "mean", next.trailing.hasPrefix(","), after != nil {
                return 2
            }
            default: break
            }
        }

        if setOffBefore, word == "you", token.trailing.isEmpty, let next, next.word == "know",
           next.trailing.hasPrefix(","), after != nil {
            return 2
        }
        // "like, um, eighty": the filler between does not decide.
        if setOffBefore, word == "like", token.trailing.hasPrefix(","), let next,
           !(hard.contains(next.word) ? after ?? next : next).keepsLike {
            return 1
        }

        // "oh" is a zero only beside a number: "oh oh seven", "five oh five".
        let number = token.isNumber || word == "oh" && (prior?.isNumber == true || next?.isNumber == true)
        if let previous, token.isWord, !number, !meantDoubles.contains(word),
           !previous.text.last!.isPunctuation, previous.word == word,
           previous.text == token.text || previous.opensSentence {
            return 1
        }
        return 0
    }
}

/// One whitespace-separated piece of a line.
private struct Token {
    let text: Substring
    /// Lowercased, edge punctuation and quotes stripped, curly apostrophes straightened.
    let word: String
    /// Trailing ",.!?;:" run, normalized: sentence marks win over commas, commas collapse.
    let trailing: String
    /// `"uh"`, `(so)`: a word quoted on purpose, never a filler.
    let isQuoted: Bool
    /// "..." does not end a sentence; an abbreviation's "." ends one only before a capital (`Fillers.clean`).
    var endsSentence: Bool
    /// "etc.", "e.g.", "p.m.": the period may be the abbreviation's own.
    let isAbbreviation: Bool

    init(_ text: Substring) {
        var body = text
        var sentence = ""
        var comma = false
        var other: Character?
        func peelMarks() {
            while let c = body.last, c.isMark {
                switch c {
                case ".", "!", "?": sentence.insert(c, at: sentence.startIndex)
                case ",": comma = true
                default: other = c
                }
                body = body.dropLast()
            }
        }
        peelMarks()
        var closing = Substring()
        if sentence.isEmpty, !comma, other == nil, body.last?.isQuote == true {
            // `"done."`: the marks sit inside the closing quote.
            while let c = body.last, c.isQuote {
                closing.insert(c, at: closing.startIndex)
                body = body.dropLast()
            }
            peelMarks()
        }
        var bare = body
        while let c = bare.first, c.isQuote { bare = bare.dropFirst() }
        while let c = bare.last, c.isQuote { bare = bare.dropLast() }
        var word = bare.lowercased()
        if word.contains("’") { word = String(word.map { $0 == "’" ? "'" : $0 }) }
        // "p.m.,": the period is the abbreviation's own, and the comma is what follows it.
        let ownPeriod = sentence == "." && comma && Fillers.abbreviations.contains(word)
        if ownPeriod { sentence = "" }
        let trailing = !sentence.isEmpty ? sentence : comma ? "," : other.map(String.init) ?? ""
        // Only a sentence mark or a comma is normalized; "std::" stays as spoken.
        self.text = sentence.isEmpty && !comma ? text : body + (ownPeriod ? "." : "") + trailing + closing
        self.trailing = trailing
        self.isQuoted = bare.count != body.count || !closing.isEmpty
        self.word = word
        self.isAbbreviation = !sentence.isEmpty && Fillers.abbreviations.contains(word)
        self.endsSentence = !sentence.isEmpty && !sentence.hasSuffix("..") && !isAbbreviation
    }

    var isPunctuationOnly: Bool { word.isEmpty && !trailing.isEmpty }
    /// A comma or a sentence end after this token sets off the one after it.
    var setsOffNext: Bool { !trailing.isEmpty }
    /// Letters and apostrophes only: digits and code are never "repeats".
    var isWord: Bool { !word.isEmpty && word.allSatisfy { $0.isLetter || $0 == "'" } }
    /// "config.json", "snake_case", "/review", "v2": never recapitalized.
    var isCode: Bool { word.contains { $0 == "." || $0 == "/" || $0 == "_" || $0.isNumber } }
    /// "ER", "UH": a name, not a filler.
    var isAcronym: Bool { text.filter(\.isLetter).count > 1 && text.allSatisfy { !$0.isLowercase } }
    /// "twenty", "twenty-six": a spoken number.
    var isNumber: Bool {
        word.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { StructuralCheck.isCardinal(String($0)) }
    }
    /// "Postgres", "JSON", "useAuth": a name. "I" and "I'm" are capitalized but name nobody.
    var isName: Bool { text.contains(where: \.isUppercase) && !Token.firstPerson.contains(word) }
    /// The speech model started a sentence here: "Um", "Then". Not "I", which is always capitalized.
    var isCapitalized: Bool { text.first(where: \.isLetter)?.isUppercase == true && !Token.firstPerson.contains(word) }
    var keepsLike: Bool { word.contains(where: \.isNumber) || isNumber || isName || Fillers.likeKeepers.contains(word) }

    static let firstPerson: Set<String> = ["i", "i'm", "i'd", "i'll", "i've"]

    static func merge(_ kept: String, _ trailing: String) -> String {
        var kept = kept
        while let last = kept.last, ",;:".contains(last) { kept.removeLast() }
        if kept.last.map({ ".!?".contains($0) }) == true { return kept }
        return kept + trailing
    }

    /// Capitalizes a new sentence start, but leaves "iPhone" and "useAuth" alone.
    static func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase,
              !text.dropFirst().contains(where: \.isUppercase) else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

private extension Character {
    var isMark: Bool {
        switch self {
        case ",", ".", "!", "?", ";", ":": true
        default: false
        }
    }
    var isQuote: Bool {
        switch self {
        case "\"", "'", "(", ")", "[", "]", "{", "}", "‘", "’", "“", "”": true
        default: false
        }
    }
}
