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
///   - hard fillers inside an interjection ("uh huh", "uh oh", "mm hmm", "ah ha") stay
///   - an immediate repeat of a function word ("the the", "I I"), unless the
///     double can be meant ("that that", "had had", "not not"). Any other word
///     said twice stays as spoken ("testing testing", "won won", "twenty twenty
///     six"): the rules can't tell a stutter from a word meant twice, so from
///     M3 the AI cleanup decides on it.
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

    /// After "like", these make it a comparison or an estimate, not a filler. So does a
    /// number word (`Fillers.isNumberWord`, from StructuralCheck's tables), a word with a
    /// digit ("like, 5 MB", "like, $5"), a name or a Term.
    static let likeKeepers: Set<String> = [
        "the", "my", "your", "his", "her", "its", "our", "their", "this", "that", "these", "those", "in", "on", "at",
        "to", "of", "for", "with", "from", "than", "as", "a", "an", "half", "few", "couple", "several", "some", "many",
        "most", "about", "around", "maybe", "under", "over", "almost", "nearly", "roughly", "twice", "thrice", "double",
        "triple", "doubled", "tripled", "quadrupled", "halved", "quarter", "quarters", "halves", "once", "teens",
        "lots", "more", "less", "between", "upwards", "somewhere", "double-digit", "triple-digit", "scores", "zillions",
    ]

    /// Two-word interjections made of filler sounds: answers and exclamations, never fillers.
    /// Only without a comma between: "uh, huh?" is a filler and then "huh".
    /// Ambiguous answers stay, including inside a number-like phrase.
    static let interjections: Set<String> = [
        "uh huh", "uh oh", "mm hmm", "mm hm", "ah ha", "ah hah", "uh uh", "um hmm", "hmm hmm", "hm hm",
    ]

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

    /// Doubles the rules keep though the word is in `StructuralCheck.stop`, on top of
    /// `protected`. Grammar allows them ("I know that that is wrong", "what it had had"),
    /// or the word is a cue or an adverb the check may drop, not a function word
    /// ("sorry sorry", "still still").
    static let meantDoubles: Set<String> = [
        "that", "had", "is", "do", "very", "too", "sorry", "scratch", "still", "already", "again", "also", "once",
        "own", "her", "you",
    ]

    /// Words that cannot end a clause: "and, um, open" becomes "and open", not "and, open".
    static let glue: Set<String> = [
        "and", "but", "or", "so", "to", "you", "it's", "is", "the", "a", "an", "of", "for", "that", "i", "we", "can",
        "just", "if", "because", "like", "at",
    ]

    /// Capitalized, but naming nobody.
    static let firstPerson: Set<String> = ["i", "i'm", "i'd", "i'll", "i've"]

    /// Titles: always followed by a name, so the capital after them never starts a sentence.
    /// ("ms" and "st" are left out: "20 ms." and "Main St." often end one.)
    static let titles: Set<String> = ["mr", "mrs", "dr"]

    /// Tokens ending in "." that need not end a sentence (`Fillers.clean` decides).
    static let abbreviations: Set<String> = titles.union([
        "e.g", "i.e", "vs", "ms", "jr", "sr", "st", "a.m", "p.m", "u.s", "u.k", "approx", "inc", "corp", "ltd",
        "co", "bros", "vol", "fig", "etc", "al", "cf", "ca", "est", "dept", "univ", "no", "ft", "lb", "lbs", "oz",
        "min", "sec", "hr", "hrs", "ave", "rd", "blvd", "mt", "jan", "feb", "mar", "apr", "jun", "jul", "aug",
        "sep", "sept", "oct", "nov", "dec",
    ])

    /// The filler pass over one line. A line always starts a sentence;
    /// `dictationStart`: no earlier line kept anything.
    static func clean(_ line: Substring, dictationStart: Bool, rules: RuleSet) -> String {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(Token.init)
        // The speech model capitalizes after a sentence end, so "etc. Um, ship it"
        // ends a sentence and "etc. um, then ship it" does not.
        for i in tokens.indices.dropLast() where tokens[i].isAbbreviation && !titles.contains(tokens[i].word) {
            // At a sentence start, "No." is an answer; "bin No." is an abbreviation.
            tokens[i].endsSentence = tokens[i + 1].isCapitalized
                || (tokens[i].word == "no" && (i == 0 || tokens[i - 1].endsSentence))
        }
        for k in tokens.indices where tokens[k].isHardFiller {
            tokens[k].isInNumber = soundInNumber(tokens, at: k)
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

            let hedge = token.word == "like"
                && likeObject(tokens, at: i).map { $0.keepsLike || rules.isWritten($0.text) } == true
            // A Term or a Rule's written side is never a filler: "OK" written by a Rule stays.
            let drop = rules.isWritten(token.text) ? 0 : dropCount(token, prior: i > 0 ? tokens[i - 1] : nil, next: next,
                                 after: i + 2 < tokens.count ? tokens[i + 2] : nil, hedge: hedge,
                                 dictationStart: dictationStart && kept.isEmpty, afterOpener: droppedOpener, setOffBefore: setOffBefore)
            if drop > 0 {
                let last = tokens[i + drop - 1]
                if sentenceKept > 0 {
                    if last.endsSentence {
                        kept[kept.count - 1] = Token.merge(kept[kept.count - 1], last.trailing)
                    } else if last.trailing.contains(","), kept[kept.count - 1].hasSuffix(","),
                              glue.contains(keptWords[keptWords.count - 1]),
                              !keptHedge(kept, keptWords, sentenceKept),
                              !addressesName(keptWords[keptWords.count - 1], i + drop < tokens.count ? tokens[i + drop] : nil) {
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

            let stutter = stutterCount(tokens, at: i, kept: kept, words: keptWords, sentenceKept: sentenceKept, rules: rules)
            if stutter > 0 {
                let last = tokens[i + stutter - 1]
                let previous = Token(Substring(kept[kept.count - 1]))
                var text = kept[kept.count - 1]
                if previous.trailing == "," || previous.trailing == "..." { text.removeLast(previous.trailing.count) }
                if sentenceKept == 1, token.isCapitalized || previous.trailing == "," {
                    text = Token.capitalized(text)
                }
                kept[kept.count - 1] = Token.merge(text, last.trailing)
                if last.endsSentence { sentenceKept = 0 }
                setOffBefore = last.setsOffNext
                i += stutter
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

    /// A filler sound at `k` inside a spoken number, before a zero "oh": "five uh oh seven",
    /// "five, uh oh oh seven" (a comma may follow the number).
    private static func soundInNumber(_ tokens: [Token], at k: Int) -> Bool {
        guard k > 0, tokens[k - 1].trailing.isEmpty || tokens[k - 1].trailing == ",", tokens[k - 1].isNumber,
              tokens[k].trailing.isEmpty else { return false }
        var j = k + 1
        while j < tokens.count, tokens[j].word == "oh" {
            if !tokens[j].trailing.isEmpty { return false }
            j += 1
        }
        return j > k + 1 && j < tokens.count && tokens[j].isNumber
    }

    /// The word a "like" at `i` hedges: the next word past filler sounds and a set-off
    /// "you know", within its sentence. "like, um, you know, eighty" hedges "eighty";
    /// "like. Ten came" and "like, um. Ten failed" hedge nothing.
    private static func likeObject(_ tokens: [Token], at i: Int) -> Token? {
        guard !tokens[i].endsSentence else { return nil }
        var j = i + 1
        while j < tokens.count {
            if tokens[j].isHardFiller {
                if tokens[j].endsSentence { return nil }
                j += 1
            } else if tokens[j].word == "you", j + 1 < tokens.count, tokens[j + 1].word == "know",
                      tokens[j + 1].trailing.hasPrefix(",") {
                j += 2
            } else {
                return tokens[j]
            }
        }
        return nil
    }

    /// "5 MB", "$5", "eighty", "twenty-something", "tenths": a number or an estimate of one.
    static func isEstimate(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || word.split(separator: "-").first.map { isNumberWord(String($0)) } ?? false
    }

    /// Cardinals, ordinals and their plurals, fractions and multiples: "ten", "third",
    /// "thirds", "twenties", "tenths", "hundredth", "twofold", "quadruple", "dozens".
    static func isNumberWord(_ word: String) -> Bool {
        if word.hasSuffix("uple"), word != "couple" { return true }
        var stems = [word]
        if word.hasSuffix("fold") { stems.append(String(word.dropLast(4))) }
        if word.hasSuffix("ies") { stems.append(word.dropLast(3) + "y") }
        if word.hasSuffix("s") { stems.append(String(word.dropLast())) }
        if word.hasSuffix("ths") { stems.append(String(word.dropLast(3))) }
        if word.hasSuffix("th") { stems.append(String(word.dropLast(2))) }
        return stems.contains {
            StructuralCheck.isCardinal($0) || StructuralCheck.ordinals[$0] != nil
                || StructuralCheck.unvalued.contains($0)
        }
    }

    /// The last kept token is a "like" set off on both sides, kept as a hedge
    /// ("takes, like, um, eighty"): its comma stays when a filler after it goes.
    private static func keptHedge(_ kept: [String], _ keptWords: [String], _ sentenceKept: Int) -> Bool {
        keptWords.last == "like" && (sentenceKept == 1 || kept[kept.count - 2].last.map { ",;:".contains($0) } == true)
    }

    /// A word whose immediate repeat is a stutter (decision 89).
    private static func canStutter(_ word: String) -> Bool {
        StructuralCheck.stop.contains(word) && !protected.contains(word) && !meantDoubles.contains(word)
    }

    /// "Where are we at, um, Jake?": a clause-final "at" before the person asked.
    /// Its comma stays when the filler goes; "Look at, um, the build" and "Meet at, um,
    /// Starbucks." lose it.
    private static func addressesName(_ keptWord: String, _ next: Token?) -> Bool {
        guard keptWord == "at", let next else { return false }
        return next.isName && next.trailing == "?"
    }

    /// Words a pseudo-cleft's clause hangs from: "what it was", "all it was", "the only thing it was".
    static let cleftHeads: Set<String> = [
        "what", "all", "thing", "reason", "problem", "issue", "point", "trouble", "catch", "idea",
    ]
    /// The subject of the clause a pseudo-cleft's first "was" closes.
    static let subjects: Set<String> = ["it", "i", "he", "she", "we", "they", "you", "that", "this"]

    /// The first "was" closes a pseudo-cleft's clause, so the predicate needs its own:
    /// "What the problem was was the cache", "All it was was a typo", "The reason it was
    /// was the cache". `sentence`: the sentence's kept words, ending with that "was".
    /// "All I did was was restart" and "the build was was green" are stutters.
    private static func closesCleft(_ sentence: ArraySlice<String>) -> Bool {
        let before = Array(sentence.dropLast().suffix(3))
        if before.contains("what") { return true }
        let pair = Array(before.suffix(2))
        return pair.count == 2 && cleftHeads.contains(pair[0]) && subjects.contains(pair[1])
    }

    /// The same word in another form: "the The", "it’s it's". Only a first-letter capital
    /// may differ, never on an acronym: "Tell IT it is down" names something.
    private static func sameSpelling(_ a: Token, _ b: Token) -> Bool {
        a.spelling == b.spelling || (!a.isAcronym && !b.isAcronym && a.spelling.dropFirst() == b.spelling.dropFirst())
    }

    /// Match spelling forms without rewriting the retained word. Only "the" and
    /// an opening "I" match across a comma; other words may end a real clause.
    private static func stutterCount(_ tokens: [Token], at i: Int, kept: [String], words: [String],
                                     sentenceKept: Int, rules: RuleSet) -> Int {
        guard sentenceKept > 0 else { return 0 }
        let token = tokens[i]
        let word = token.word
        guard canStutter(word), !token.isQuoted, !rules.isWritten(token.text) else { return 0 }
        let previous = Token(Substring(kept[kept.count - 1]))
        guard !previous.isQuoted, !rules.isWritten(previous.text) else { return 0 }

        if sentenceKept >= 2, token.word == "in", token.trailing.isEmpty, i + 1 < tokens.count {
            let next = tokens[i + 1]
            let before = Token(Substring(kept[kept.count - 2]))
            if before.word == "in", before.trailing.isEmpty, !before.isQuoted,
               sameSpelling(before, token), previous.word == "the", previous.trailing.isEmpty, sameSpelling(previous, next),
               next.word == "the", !next.isQuoted, !rules.isWritten(next.text), !rules.isWritten(before.text) {
                return 2
            }
        }

        let commaStutter = previous.trailing == "," && (word == "the" || (word == "i" && sentenceKept == 1))
        // "the... the build": the trailing off goes with the dropped copy.
        let marked = previous.trailing.isEmpty || previous.trailing == "..." || commaStutter
        guard previous.word == word, marked, sameSpelling(previous, token) else { return 0 }
        // "Will will review it", "May may be late": a name, then the modal.
        if word == "will" || word == "may", previous.isName { return 0 }
        if word == "was", closesCleft(words.suffix(sentenceKept)) { return 0 }
        return 1
    }

    /// How many tokens from `token` on are fillers to delete: 0, 1 or 2.
    /// `prior`: the token just before, kept or not. `hedge`: a "like" before a number, a name or a Term.
    /// `dictationStart`: nothing kept yet in the Dictation. `afterOpener`: a filler already went from this sentence's start.
    private static func dropCount(_ token: Token, prior: Token?, next: Token?, after: Token?, hedge: Bool,
                                  dictationStart: Bool, afterOpener: Bool,
                                  setOffBefore: Bool)
        -> Int {
        let word = token.word
        if protected.contains(word) || token.isQuoted { return 0 }
        if word == "i-", let next, next.word == "i", !next.isQuoted { return 1 }
        if token.isHardFiller {
            // A sound of "uh huh" or "mm hmm" is a word, unless it sits inside a number ("five uh oh seven").
            if let next, token.trailing.isEmpty, !token.isInNumber, interjections.contains(word + " " + next.word) {
                return 0
            }
            if let prior, prior.trailing.isEmpty, interjections.contains(prior.word + " " + word) { return 0 }
            return 1
        }

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
        if setOffBefore, word == "like", token.trailing.hasPrefix(","), next != nil, !hedge {
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
    /// Set by `Fillers.clean` from the tokens around: a filler sound inside a spoken number.
    var isInNumber = false

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
        word = String(word.map(\.straightened))
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
    /// The word as written, case kept, marks dropped and apostrophes straightened: "it’s," is "it's".
    var spelling: String {
        var body = text
        while let c = body.last, c.isMark { body = body.dropLast() }
        return String(body.map(\.straightened))
    }
    /// "IT", "WHO", "OR": a name even at a sentence start. Not "I".
    var isAcronym: Bool { text.filter(\.isLetter).count > 1 && !text.contains(where: \.isLowercase) }
    /// A comma or a sentence end after this token sets off the one after it.
    var setsOffNext: Bool { !trailing.isEmpty }
    /// "config.json", "snake_case", "/review", "v2": never recapitalized.
    var isCode: Bool { word.contains { $0 == "." || $0 == "/" || $0 == "_" || $0.isNumber } }
    /// "um", "Uh"; not "ER" or "UH", which are names.
    var isHardFiller: Bool {
        Fillers.hard.contains(word) && !isAcronym
    }
    /// "5", "twenty", "twenty-six", "thirty-something": a number as said or written.
    var isNumber: Bool {
        word.first?.isNumber == true
            || word.split(separator: "-").first.map {
                StructuralCheck.isCardinal(String($0)) || StructuralCheck.unvalued.contains(String($0))
            } ?? false
    }
    /// "Postgres", "JSON", "useAuth": a name. "I" and "I'm" are capitalized but name nobody.
    var isName: Bool { text.contains(where: \.isUppercase) && !Fillers.firstPerson.contains(word) }
    /// The speech model started a sentence here: "Um", "Then". Not "I", which is always capitalized.
    var isCapitalized: Bool {
        text.first(where: \.isLetter)?.isUppercase == true && !Fillers.firstPerson.contains(word)
    }
    var keepsLike: Bool { Fillers.isEstimate(word) || isName || Fillers.likeKeepers.contains(word) }

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
    /// "we’re" and "we‘re" are "we're".
    var straightened: Character { self == "’" || self == "‘" ? "'" : self }
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
