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
/// Rules-applied text (`ruled`), fillers still in, never the LLM's own idea of
/// what was said, so a Rule's output counts as spoken.
///
/// Words are compared by membership, not alignment: a word kept anywhere in the
/// candidate counts as kept, so a word repeated in a self-correction or a list
/// is still found. Case and punctuation never matter. Passes when all hold:
///   - no code block or code-looking token nobody spoke (`unspokenCode`)
///   - spoken numbers and digits agree, in the order spoken: "one hundred" is
///     "100", "two million" is "2,000,000", "fourth" is "4th" (`numberMismatch`)
///   - every content word of `ruled` survives, except a filler where the rules
///     would also drop it, or a word retracted by a self-correction ("delete
///     them, actually no, move them"). Negation, constraint and hedge words
///     (`mustKeep`) are content words here (`droppedContentWord`)
///   - no content word is added; Lexicon `terms`, list markers ("1.", "-", "•")
///     and the ordinals those markers replace are allowed. No negation or hedge
///     appears more often than it was spoken (`addedWord`), or less often,
///     unless retracted (`droppedContentWord`)
///   - at most `lengthCap` times the ruled length plus `lengthSlack` tokens (`tooLong`)
/// Function words ("the", "to", "it's", "can") may come and go: dropping or
/// adding one never changes what was asked.
///
/// Known blind spots, measured on the research bench (branch research/llm-cleanup):
/// a self-correction span runs from the start of its sentence to the cue, so a
/// clause in that sentence that was not retracted may go too; list markers
/// excuse missing small numbers and ordinals; a correction resolved into other
/// words, or back into its retracted words, passes if it adds no content word;
/// word order is not checked, so swapped nouns ("from staging to prod") and
/// swapped modals ("have to" to "can") pass. And it is strict where it could be
/// lenient: a close miss the model fixes into a Term ("super base" to
/// "Supabase") fails, because the misheard words are gone.
enum StructuralCheck {
    static let lengthCap = 1.2
    /// A short Dictation turned into a list gains a marker per line: "1. Ship it." on "Ship it."
    static let lengthSlack = 4

    /// nil = accept. Otherwise the first failing check, in the order listed above.
    /// `rules`: the RuleSet the rules pass used, so a "like" before a Rule's written side
    /// is a hedge here too; without it, only `terms` count.
    static func check(_ candidate: String, ruled: String, terms: [Term], rules: RuleSet? = nil) -> CheckFailure? {
        if hasUnspokenCode(candidate, ruled: ruled) { return .unspokenCode }
        let (outText, markers) = stripListMarkers(candidate)
        let (refText, _) = stripListMarkers(ruled)
        let out = canonical(tokens(outText))
        if out.isEmpty { return .droppedContentWord }
        let ref = canonical(tokens(refText))

        var failures = Set<CheckFailure>()
        let kept = Set(out.map(\.word))
        let retracted = retractedSpans(ref)
        let openers = openerRun(ref)
        for (k, token) in ref.enumerated() where !retracted.contains(k) && !kept.contains(token.word) {
            let word = token.word
            if Fillers.hard.contains(word) {
                continue
            } else if softFillers.contains(word) {
                if !softFillerMayGo(ref, k, inOpener: openers[k]) { failures.insert(.droppedContentWord) }
            } else if mustKeep.contains(word) {
                failures.insert(.droppedContentWord)
            } else if stop.contains(word) {
                continue
            } else if markers > 0, listSequence.contains(word) || smallNumber(word) {
                continue
            } else {
                failures.insert(isNumber(word) ? .numberMismatch : .droppedContentWord)
            }
        }

        // A filler the rules keep as meaning survives, unless retracted: a sound of "uh huh",
        // and a "like" before a number, a name or a Term, with the word it hedges still after
        // it ("like 80"), so another "like" kept elsewhere is no excuse.
        var meant: [String: Int] = [:]
        let names = capitalizedWords(refText)
        for k in ref.indices where !retracted.contains(k) {
            guard let key = meaningKey(ref, k) else { continue }
            if ref[k].word == "like" {
                guard ref[k].mark == ",", let object = likeObject(ref, k)?.word,
                      Fillers.isEstimate(object) || names.contains(object) || rules?.isWritten(object) == true
                        || terms.contains(where: { $0.text.lowercased() == object }) else { continue }
            }
            meant[key, default: 0] += 1
        }
        for (key, count) in meant where out.indices.filter({ meaningKey(out, $0) == key }).count < count {
            failures.insert(.droppedContentWord)
        }

        let spokenWords = Set(ref.map(\.word))
        var lexicon: Set<String>?  // only when a word was added: up to 200 Terms
        for token in out where !spokenWords.contains(token.word) {
            let word = token.word
            if !mustKeep.contains(word), stop.contains(word) || softFillers.contains(word)
                || Fillers.hard.contains(word) || listSequence.contains(word) {
                continue
            }
            if lexicon == nil { lexicon = Set(terms.flatMap { canonical(tokens($0.text)).map(\.word) }) }
            if lexicon!.contains(word) { continue }
            failures.insert(isNumber(word) ? .numberMismatch : .addedWord)
        }
        // Each negation and hedge counts, not just the word: "don't delete X, and don't
        // merge Y" must not lose its second "don't", and "don't touch X, but update Y"
        // must not gain one. Retracted ones may go.
        var negations: [String: Int] = [:]
        for token in out where mustKeep.contains(token.word) { negations[token.word, default: 0] += 1 }
        var spoken: [String: (all: Int, kept: Int)] = [:]
        for (k, token) in ref.enumerated() where mustKeep.contains(token.word) {
            spoken[token.word, default: (0, 0)].all += 1
            if !retracted.contains(k) { spoken[token.word, default: (0, 0)].kept += 1 }
        }
        if spoken.contains(where: { negations[$0.key, default: 0] < $0.value.kept }) {
            failures.insert(.droppedContentWord)
        }
        if negations.contains(where: { $0.value > spoken[$0.key]?.all ?? 0 }) {
            failures.insert(.addedWord)
        }
        // "14 days ... 1 year" must not become "1 year ... 14 days": numbers keep their order.
        let spokenNumbers = ref.map(\.word).filter(isNumber)
        var next = 0
        for number in out.map(\.word) where isNumber(number) {
            guard let at = spokenNumbers[next...].firstIndex(of: number) else {
                failures.insert(.numberMismatch)
                break
            }
            next = at + 1
        }

        if Double(out.count + markers) > lengthCap * Double(ref.count) + Double(lengthSlack) {
            failures.insert(.tooLong)
        }
        return [CheckFailure.numberMismatch, .droppedContentWord, .addedWord, .tooLong].first(where: failures.contains)
    }

    // MARK: Word lists, all lowercase.

    /// Dropped only where they are set off (`softFillerMayGo`). "you know" and
    /// "I mean" are joined into one token first.
    static let softFillers: Set<String> = ["like", "so", "well", "okay", "ok", "basically", "you_know", "i_mean"]

    /// Negation, constraint and hedge words: never dropped, never added, except
    /// inside a self-correction. "not sure" keeps its "sure".
    static let mustKeep: Set<String> = [
        "not", "no", "never", "nor", "none", "nothing", "nobody", "nowhere", "only", "except", "without", "unless",
        "instead", "avoid", "think", "maybe", "might", "perhaps", "probably", "possibly", "guess", "sure", "unsure",
        "seems", "seem", "likely", "should", "must",
        "don't", "dont", "doesn't", "doesnt", "didn't", "didnt", "won't", "wont", "can't", "cant", "cannot",
        "shouldn't", "shouldnt", "isn't", "isnt", "aren't", "arent", "wasn't", "wasnt", "weren't", "werent",
        "haven't", "havent", "hasn't", "hasnt", "hadn't", "hadnt", "wouldn't", "wouldnt", "couldn't", "couldnt",
        "mustn't", "mustnt", "mightn't", "needn't",
    ]

    /// Function words: dropping or adding one never changes what was asked.
    /// "sorry", "scratch" and "actually" are here because they only ever cue a self-correction.
    /// Words that flip a meaning when swapped for their opposite ("under", "off", "all", "even")
    /// are content words, so "under 5 MB" cannot become "over 5 MB".
    static let stop: Set<String> = [
        "a", "an", "the", "and", "or", "but", "yet", "if", "then", "than", "that", "this", "these", "those",
        "there", "here", "of", "to", "in", "on", "at", "by", "for", "with", "from", "into", "onto", "about", "as",
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "have", "has", "had",
        "having", "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your", "yours", "he", "him", "his",
        "she", "her", "hers", "it", "its", "they", "them", "their", "theirs", "what", "which", "who", "whom",
        "whose", "when", "where", "why", "how", "both", "each", "some", "such", "own", "very", "just", "also",
        "too", "still", "already", "again", "once", "actually", "really", "sorry", "scratch", "can", "will",
        "shall", "could", "would", "may", "it's", "i'm", "i'll", "i've", "i'd", "that's", "there's", "what's",
        "let's", "here's", "we're", "they're", "you're", "we'll", "he's", "she's", "who's",
    ]

    /// Words a numbered or bulleted list replaces ("first, pull main" becomes "1. Pull main.").
    static let listSequence: Set<String> = ["next", "finally", "lastly"]

    // MARK: Tokens

    struct Token: Equatable {
        var word: String
        /// The punctuation mark that ended this token in the text, if any.
        var mark: Unicode.Scalar?
    }

    static let marks: Set<Unicode.Scalar> = [".", ",", "!", "?", ";", ":"]
    static let sentenceMarks: Set<Unicode.Scalar> = [".", "!", "?"]
    static let edges: Set<Unicode.Scalar> = [
        ".", ",", "!", "?", ";", ":", "\"", "'", "(", ")", "[", "]", "{", "}", "<", ">", "*", "`", "\u{201C}", "\u{201D}",
    ]

    /// Lowercased words with their trailing mark. Edge punctuation and quotes go,
    /// hyphenated words split ("re-render" is "re" and "render"), curly
    /// apostrophes and Unicode hyphens are made ASCII, and an em dash is a space.
    /// One pass over Unicode scalars: this runs on every Dictation.
    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var piece: [Unicode.Scalar] = []
        func endPiece() {
            defer { piece.removeAll(keepingCapacity: true) }
            guard let last = piece.last else { return }
            let mark = marks.contains(last) ? last : nil
            var lo = 0
            var hi = piece.count
            while lo < hi, edges.contains(piece[lo]) { lo += 1 }
            while hi > lo, edges.contains(piece[hi - 1]) { hi -= 1 }
            let parts = piece[lo..<hi].split(separator: "-")
            if parts.isEmpty {
                if piece == ["-"] {
                    result.append(Token(word: "-", mark: nil))
                } else if mark != nil, !result.isEmpty {
                    result[result.count - 1].mark = mark
                }
                return
            }
            for (i, part) in parts.enumerated() {
                var word = String.UnicodeScalarView()
                word.append(contentsOf: part)
                result.append(Token(word: String(word), mark: i == parts.count - 1 ? mark : nil))
            }
        }
        for scalar in text.lowercased().unicodeScalars {
            switch scalar {
            case "\u{2019}", "\u{2018}": piece.append("'")
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}": piece.append("-")
            case "\u{2014}": endPiece()
            case " ", "\n", "\t", "\r", "\u{0B}", "\u{0C}": endPiece()
            default:
                if !scalar.isASCII, scalar.properties.isWhitespace { endPiece() } else { piece.append(scalar) }
            }
        }
        endPiece()
        return result
    }

    // MARK: Numbers

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000, "trillion": 1_000_000_000_000,
        "quadrillion": 1_000_000_000_000_000,
    ]
    static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
        "ninetieth": 90,
    ]

    static func isCardinal(_ word: String) -> Bool {
        units[word] != nil || scales[word] != nil || word == "hundred"
    }

    /// One spoken number ends at a mark ("one, two, three" is three numbers) or
    /// at the first word that is not part of it; "and" joins "one hundred and twenty".
    static func cardinalRunEnd(_ input: [Token], from start: Int) -> Int {
        var j = start
        while j < input.count, isCardinal(input[j].word) {
            j += 1
            if input[j - 1].mark != nil { break }
            if j + 1 < input.count, input[j].word == "and", input[j].mark == nil, units[input[j + 1].word] != nil,
               input[j - 1].word == "hundred" || scales[input[j - 1].word] != nil {
                j += 1
            }
        }
        return j
    }

    /// Wrapping arithmetic: "hundred hundred hundred ..." must not trap. Both
    /// sides wrap the same way, so a nonsense number still compares equal to itself.
    static func cardinalValue(_ words: some Collection<String>) -> Int {
        var total = 0
        var current = 0
        for word in words {
            if let unit = units[word] {
                current &+= unit
            } else if word == "hundred" {
                current = (current == 0 ? 1 : current) &* 100
            } else if let scale = scales[word] {
                total &+= (current == 0 ? 1 : current) &* scale
                current = 0
            }
        }
        return total &+ current
    }

    /// "123", "2,000,000", "3.5", with commas removed. nil if not a number.
    static func digitValue(_ word: String) -> String? {
        guard let first = word.first, first.isASCII, first.isNumber else { return nil }
        let parts = word.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty else { return nil }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(isDigit) { return nil }
        let groups = whole.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isDigit) }) else { return nil }
        if groups.count > 1, groups[0].count > 3 || groups.dropFirst().contains(where: { $0.count != 3 }) { return nil }
        return groups.joined() + (parts.count == 2 ? "." + parts[1] : "")
    }

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// "4th", "21st", "2nd" as the ordinal's value. nil if not a digit ordinal.
    static func digitOrdinal(_ word: String) -> Int? {
        guard word.count > 2, ["st", "nd", "rd", "th"].contains(word.suffix(2)) else { return nil }
        let digits = word.dropLast(2)
        guard digits.allSatisfy(isDigit) else { return nil }
        return Int(digits)
    }

    /// Ordinals become "nth 4" for both "fourth" and "4th". Tokens are split at
    /// whitespace, so no word from the text can look like one.
    static func ordinalWord(_ value: Int) -> String { "nth \(value)" }

    static func isNumber(_ word: String) -> Bool {
        ordinalValue(word) != nil || digitValue(word) != nil
    }

    static func ordinalValue(_ word: String) -> Int? {
        word.hasPrefix("nth ") ? Int(word.dropFirst(4)) : nil
    }

    /// A list marker stands in for these when they go missing: "one, rebase" becomes "1. Rebase".
    static func smallNumber(_ word: String) -> Bool {
        if let value = ordinalValue(word) { return value <= 20 }
        guard let value = digitValue(word), !value.contains("."), let n = Int(value) else { return false }
        return n <= 20
    }

    /// Spoken numbers and ordinals as digits, digit commas removed, "two million"
    /// and "2 million" as "2000000", "you know" and "I mean" joined, "plus" and
    /// "minus" between numbers as "+" and "-".
    static func canonical(_ input: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < input.count {
            let token = input[i]
            if isCardinal(token.word) {
                var j = cardinalRunEnd(input, from: i)
                let value = cardinalValue(input[i..<j].map(\.word))
                if j < input.count, input[j - 1].mark == nil, let ordinal = ordinals[input[j].word], ordinal < 10,
                   value > 0, value % 10 == 0 {
                    // "twenty first"
                    out.append(Token(word: ordinalWord(value &+ ordinal), mark: input[j].mark))
                    i = j + 1
                    continue
                }
                var word = String(value)
                if input[j - 1].mark == nil, j + 1 < input.count, input[j].word == "point",
                   let d = units[input[j + 1].word], d < 10 {
                    var k = j + 1
                    var decimals = ""
                    while k < input.count, let d = units[input[k].word], d < 10 {
                        decimals += String(d)
                        k += 1
                        if input[k - 1].mark != nil { break }
                    }
                    word += "." + decimals
                    j = k
                }
                out.append(Token(word: word, mark: input[j - 1].mark))
                i = j
                continue
            }
            if let ordinal = ordinals[token.word] ?? digitOrdinal(token.word) {
                out.append(Token(word: ordinalWord(ordinal), mark: token.mark))
                i += 1
                continue
            }
            if var value = digitValue(token.word) {
                var j = i + 1
                if j < input.count, token.mark == nil, let scale = scales[input[j].word], !value.contains("."),
                   let n = Int(value) {
                    value = String(n &* scale)
                    j += 1
                }
                out.append(Token(word: value, mark: input[j - 1].mark))
                i = j
                continue
            }
            out.append(token)
            i += 1
        }

        var joined: [Token] = []
        var k = 0
        while k < out.count {
            if k + 1 < out.count, (out[k].word == "you" && out[k + 1].word == "know")
                || (out[k].word == "i" && out[k + 1].word == "mean") {
                joined.append(Token(word: out[k].word + "_" + out[k + 1].word, mark: out[k + 1].mark))
                k += 2
            } else {
                joined.append(out[k])
                k += 1
            }
        }
        if joined.count > 2 {
            for k in 1..<(joined.count - 1) where joined[k].word == "plus" || joined[k].word == "minus" {
                if digitValue(joined[k - 1].word) != nil, digitValue(joined[k + 1].word) != nil {
                    joined[k].word = joined[k].word == "plus" ? "+" : "-"
                }
            }
        }
        return joined
    }

    // MARK: Self-corrections and fillers

    static func endsSentence(_ token: Token) -> Bool { token.mark.map(sentenceMarks.contains) ?? false }

    /// Token indices a self-correction retracts: from the start of the cue's
    /// sentence (or the sentence before, when a clear cue opens its own) through the cue.
    /// Cues: "actually no", "no actually", "no wait", "wait no", "scratch that",
    /// "sorry", "or rather", and a lone ", no,".
    static func retractedSpans(_ ref: [Token]) -> Set<Int> {
        var starts = [0]
        for k in 0..<max(ref.count - 1, 0) where endsSentence(ref[k]) { starts.append(k + 1) }

        var spans = Set<Int>()
        for p in ref.indices {
            let word = ref[p].word
            let next = p + 1 < ref.count ? ref[p + 1].word : ""
            // `reachesBack`: opening a sentence, the cue retracts the sentence before.
            // "Sorry" and a lone "no" may open a sentence without correcting it.
            let cue: (start: Int, length: Int, reachesBack: Bool)? = switch word {
            case "actually" where next == "no": (p, 2, true)
            case "no" where next == "actually" || next == "wait": (p, 2, true)
            case "wait" where next == "no": (p, 2, true)
            case "scratch" where next == "that": (p, 2, true)
            case "sorry": (p, 1, false)
            case "rather" where p > 0 && ref[p - 1].word == "or": (p - 1, 2, true)
            case "no" where p > 0 && ref[p - 1].mark == "," && ref[p].mark == ",": (p, 1, false)
            default: nil
            }
            guard let cue else { continue }
            let sentence = starts.last(where: { $0 <= cue.start })!
            let from = cue.reachesBack && cue.start == sentence && sentence > 0
                ? starts.last(where: { $0 < sentence })! : sentence
            spans.formUnion(from..<min(cue.start + cue.length, ref.count))
        }
        return spans
    }

    /// For each token: is everything before it in its sentence a filler? "Okay so, um, here's"
    /// opens with "Okay so".
    static func openerRun(_ ref: [Token]) -> [Bool] {
        var result: [Bool] = []
        var open = true
        for token in ref {
            result.append(open)
            open = endsSentence(token) || (open && (Fillers.hard.contains(token.word) || softFillers.contains(token.word)))
        }
        return result
    }

    /// A filler as the rules keep it for its meaning, to find again in the output:
    /// "uh huh" for a sound of an interjection, "like 80" for a "like" and the word
    /// after it. nil for any other word, and for "uh" before an "oh" that is a zero
    /// inside a number ("5 uh oh 7").
    static func meaningKey(_ t: [Token], _ k: Int) -> String? {
        let word = t[k].word
        if word == "like" { return likeObject(t, k).map { "like " + $0.word } }
        guard Fillers.hard.contains(word) else { return nil }
        if t[k].mark == nil, k + 1 < t.count, Fillers.interjections.contains(word + " " + t[k + 1].word) {
            let zero = t[k + 1].word == "oh" && t[k + 1].mark == nil && k + 2 < t.count && isNumber(t[k + 2].word)
                && k > 0 && t[k - 1].mark == nil && isNumber(t[k - 1].word)
            return zero ? nil : word + " " + t[k + 1].word
        }
        if k > 0, t[k - 1].mark == nil, Fillers.interjections.contains(t[k - 1].word + " " + word) {
            return t[k - 1].word + " " + word
        }
        return nil
    }

    /// The word a "like" hedges (`Fillers.likeObject`), on canonical tokens, where
    /// "you know" is one token.
    static func likeObject(_ t: [Token], _ k: Int) -> Token? {
        Fillers.likeObject(count: t.count, at: k, isFiller: { Fillers.hard.contains(t[$0].word) },
                           endsSentence: { endsSentence(t[$0]) },
                           youKnow: { t[$0].word == "you_know" && t[$0].mark == "," ? 1 : 0 })
            .map { t[$0] }
    }

    /// Lowercased words written with a capital past a sentence's first word ("Postgres",
    /// "useAuth"): names, as far as lowercased tokens can tell. "I" and its forms name nobody.
    static func capitalizedWords(_ text: String) -> Set<String> {
        var names = Set<String>()
        var sentenceStart = true
        for piece in text.split(whereSeparator: \.isWhitespace) {
            var word = piece
            while let c = word.first, !c.isLetter { word = word.dropFirst() }
            while let c = word.last, !c.isLetter { word = word.dropLast() }
            if word.dropFirst().contains(where: \.isUppercase) || !sentenceStart && word.first?.isUppercase == true,
               !Fillers.firstPerson.contains(word.lowercased()) {
                names.insert(word.lowercased())
            }
            sentenceStart = piece.last.map { ".!?".contains($0) } ?? false
        }
        return names
    }

    /// Where the rules would also drop it: "like" before a comma or a sentence
    /// end; "so" opening its sentence or set off on both sides; the rest when set
    /// off on either side.
    static func softFillerMayGo(_ ref: [Token], _ k: Int, inOpener: Bool) -> Bool {
        let before = k == 0 || ref[k - 1].mark != nil
        let after = ref[k].mark != nil || k == ref.count - 1
        switch ref[k].word {
        case "like": return ref[k].mark == "," || endsSentence(ref[k])
        case "so": return inOpener || (before && after)
        default: return before || after
        }
    }

    // MARK: Shape

    /// Removes a leading "1.", "2)", "-", "*" or "•" marker from each line. Returns the text and the count.
    static func stripListMarkers(_ text: String) -> (String, Int) {
        var count = 0
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> Substring in
            let body = line.drop(while: { $0 == " " || $0 == "\t" })
            var rest = body
            if let c = rest.first, c == "-" || c == "*" || c == "•" {
                rest = rest.dropFirst()
            } else {
                let digits = rest.prefix(while: isDigit)
                guard (1...2).contains(digits.count) else { return line }
                rest = rest.dropFirst(digits.count)
                guard let c = rest.first, c == "." || c == ")" else { return line }
                rest = rest.dropFirst()
            }
            guard let space = rest.first, space == " " || space == "\t" else { return line }
            count += 1
            return rest.drop(while: { $0 == " " || $0 == "\t" })
        }
        return (lines.joined(separator: "\n"), count)
    }

    static let codeTokens = ["```", "{", "}", "=>", "();", "#include", "</", "def ", "import ", "func "]
        .map { Array($0.utf8) }

    /// A fence, a brace or a line indented as code that the ruled text does not have.
    static func hasUnspokenCode(_ candidate: String, ruled: String) -> Bool {
        let out = Array(candidate.utf8)
        let ref = Array(ruled.utf8)
        if codeTokens.contains(where: { contains(out, $0) && !contains(ref, $0) }) { return true }
        return hasIndentedLine(out) && !hasIndentedLine(ref)
    }

    static func contains(_ text: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= text.count else { return false }
        return (0...(text.count - needle.count)).contains { i in
            text[i] == needle[0] && text[i..<(i + needle.count)].elementsEqual(needle)
        }
    }

    /// A line that starts with four spaces or a tab, then text.
    static func hasIndentedLine(_ text: [UInt8]) -> Bool {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), newline = UInt8(ascii: "\n")
        var i = 0
        while i < text.count {
            var j = i
            if text[j] == tab {
                j += 1
            } else {
                while j < text.count, text[j] == space { j += 1 }
                if j - i < 4 { j = i }
            }
            if j > i, j < text.count, ![space, tab, newline, UInt8(ascii: "\r")].contains(text[j]) { return true }
            while i < text.count, text[i] != newline { i += 1 }
            i += 1
        }
        return false
    }
}
