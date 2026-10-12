import Foundation

/// Re-speak's candidate finder (M4): which span of the recent text did Jake
/// just say again? Every span of 1 to 3 words, ranked by how much it sounds
/// like the re-spoken words. Pure and local: Private mode picks from this
/// ranking alone, and Jev is sent only its first few.
public enum CandidateFinder {
    /// Spans are 1 to 3 words: a Re-speak fixes a word or a short name, never a phrase.
    static let longestSpan = 3
    /// How much of a span's distance is sound; the rest is spelling, which
    /// separates spans that sound alike ("eight": "ate" before "to").
    static let soundWeight = 0.7

    /// Every span of 1 to 3 words in `recent` (split on whitespace), best
    /// sounding first. Ties go to the span nearer the end, where the caret is.
    /// Punctuation at a span's edges is not part of it: replacing "super base."
    /// keeps the period.
    public static func candidates(for spoken: String, in recent: String) -> [SpanCandidate] {
        let said = Pronunciation.ways(of: spoken)
        guard !said.isEmpty else { return [] }
        let words = recent.split(whereSeparator: \.isWhitespace).map(Self.core)
        var found: [SpanCandidate] = []
        for start in words.indices {
            guard let first = words[start] else { continue }
            for end in start..<min(start + longestSpan, words.count) {
                guard let last = words[end] else { continue }
                let text = String(recent[first.lowerBound..<last.upperBound])
                let heard = Pronunciation(text)
                let distance = said.map { $0.distance(to: heard, soundWeight: soundWeight) }.min()!
                let utf16 = recent.utf16.distance(from: recent.startIndex, to: first.lowerBound)
                found.append(SpanCandidate(words: start..<end + 1, text: text,
                                           utf16: utf16..<utf16 + text.utf16.count,
                                           phonetic: heard.sound, distance: distance))
            }
        }
        return found.sorted { a, b in
            a.distance != b.distance ? a.distance < b.distance : a.words.lowerBound > b.words.lowerBound
        }
    }

    /// A word without the punctuation at its edges; nil when nothing is left.
    private static func core(_ word: Substring) -> Range<String.Index>? {
        guard let start = word.firstIndex(where: { !edgePunctuation.contains($0) }),
              let last = word.lastIndex(where: { !edgePunctuation.contains($0) })
        else { return nil }
        return start..<word.index(after: last)
    }

    private static let edgePunctuation = Set(".,;:!?\"'()[]{}<>“”‘’…")
}

/// One span of the recent text a Re-speak might replace.
public struct SpanCandidate: Sendable, Hashable {
    /// Word indexes into the recent text, split on whitespace (as Jev counts them).
    public let words: Range<Int>
    /// The span as written, without the punctuation at its edges.
    public let text: String
    /// Where `text` sits in the recent text, in UTF-16 offsets, for the replace.
    public let utf16: Range<Int>
    /// `Phonetic.code(text)`: Jev reads text only, so it gets the sound as text too.
    public let phonetic: String
    /// 0 sounds the same as the re-spoken words, 1 nothing alike.
    public let distance: Double

    public init(words: Range<Int>, text: String, utf16: Range<Int>, phonetic: String, distance: Double) {
        self.words = words
        self.text = text
        self.utf16 = utf16
        self.phonetic = phonetic
        self.distance = distance
    }
}

/// A rough English sound code in the spirit of Metaphone: consonant sounds,
/// with a vowel marked only where the text starts. Spaces, case, hyphens and a
/// possessive 's don't count, and joined words split where their case changes,
/// so "super base", "Super-Base" and "SuperBase" sound the same.
public enum Phonetic {
    public static func code(_ text: String) -> String { Pronunciation(text).sound }
}

/// Text as sound and as bare letters, the two things a span is compared on.
struct Pronunciation {
    /// `Phonetic.code`.
    let sound: String
    /// Lowercase ASCII letters and digits only.
    let letters: String

    init(_ text: String) {
        let pieces = Self.pieces(text)
        var sound: [Character] = []
        for (index, piece) in pieces.enumerated() {
            for symbol in Self.sound(of: piece, startsText: index == 0) where sound.last != symbol {
                sound.append(symbol)
            }
        }
        self.sound = String(sound)
        letters = String(pieces.joined())
    }

    /// How Jake may have said `spoken`: as written, and for an acronym ("SQL",
    /// "CLI") also letter by letter, since a recognizer can write either.
    static func ways(of spoken: String) -> [Pronunciation] {
        let written = Pronunciation(spoken)
        guard !written.letters.isEmpty else { return [] }
        let pieces = spoken.split(whereSeparator: \.isWhitespace).flatMap { casePieces(String($0)) }
        guard pieces.contains(where: isAcronym) else { return [written] }
        let spelled = pieces.map { piece in
            isAcronym(piece) ? piece.map { letterNames[Character($0.lowercased())] ?? "" }.joined(separator: " ") : piece
        }
        return [written, Pronunciation(spelled.joined(separator: " "))]
    }

    /// 0 the same, 1 nothing alike: mostly sound, the rest spelling.
    func distance(to other: Pronunciation, soundWeight: Double) -> Double {
        soundWeight * Self.distance(sound, other.sound) + (1 - soundWeight) * Self.distance(letters, other.letters)
    }

    // MARK: Splitting

    /// The words of `text` as lowercase ASCII, split at spaces, punctuation and
    /// case changes, with a possessive 's dropped.
    private static func pieces(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).flatMap { word -> [String] in
            var word = String(word)
            for possessive in ["'s", "’s"] where word.lowercased().hasSuffix(possessive) { word.removeLast(2) }
            return casePieces(word).map { $0.lowercased() }
        }
    }

    /// "OpenAI" is "Open", "AI"; "JSONData" is "JSON", "Data"; "Next.js" is
    /// "Next", "js". Accents folded, everything but ASCII letters and digits dropped.
    private static func casePieces(_ word: String) -> [String] {
        let folded = Array(word.folding(options: .diacriticInsensitive, locale: nil))
        var pieces: [String] = []
        var piece = ""
        for (index, character) in folded.enumerated() {
            guard character.isASCII, character.isLetter || character.isNumber else {
                if !piece.isEmpty { pieces.append(piece) }
                piece = ""
                continue
            }
            let next = index + 1 < folded.count ? folded[index + 1] : nil
            let previous = piece.last
            let lowerToUpper = character.isUppercase && previous.map { !$0.isUppercase } == true
            let acronymEnds = character.isUppercase && previous?.isUppercase == true && next?.isLowercase == true
            if lowerToUpper || acronymEnds {
                pieces.append(piece)
                piece = ""
            }
            piece.append(character)
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    private static func isAcronym(_ piece: String) -> Bool {
        (2...5).contains(piece.count) && piece.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    private static let letterNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "ef", "g": "jee", "h": "aitch", "i": "eye",
        "j": "jay", "k": "kay", "l": "el", "m": "em", "n": "en", "o": "oh", "p": "pee", "q": "cue", "r": "ar",
        "s": "es", "t": "tee", "u": "you", "v": "vee", "w": "double you", "x": "ex", "y": "why", "z": "zee",
    ]

    // MARK: Sound

    /// One word's consonant sounds. Voiced and voiceless pairs share a symbol
    /// (b p, d t, g k, v f, z s): a recognizer mixes them up more than Jake does.
    private static func sound(of word: String, startsText: Bool) -> [Character] {
        let w = Array(word)
        func at(_ i: Int) -> Character? { w.indices.contains(i) ? w[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "aeiou".contains($0) } ?? false }
        func softens(_ c: Character?) -> Bool { c.map { "eiy".contains($0) } ?? false }
        var out: [Character] = []
        var i = 0
        while i < w.count {
            let c = w[i], next = at(i + 1)
            var symbols = ""
            var step = 1
            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 && startsText { symbols = "A" }
            case "y":
                if isVowel(next) { symbols = "Y" }
            case "c":
                if next == "h" { symbols = "X"; step = 2 }
                else if next == "k" { symbols = "K"; step = 2 }
                else { symbols = softens(next) ? "S" : "K" }
            case "s":
                if next == "h" { symbols = "X"; step = 2 }
                else if next == "i", at(i + 2) == "o" || at(i + 2) == "a" { symbols = "X"; step = 2 }
                else if next == "c", softens(at(i + 2)) { symbols = "S"; step = 2 }
                else { symbols = "S" }
            case "t":
                if next == "h" { symbols = "0"; step = 2 }
                else if next == "i", at(i + 2) == "o" || at(i + 2) == "a" { symbols = "X"; step = 2 }
                else if next == "c", at(i + 2) == "h" { symbols = "X"; step = 3 }
                else { symbols = "T" }
            case "d":
                if next == "g", softens(at(i + 2)) { symbols = "J"; step = 2 } else { symbols = "T" }
            case "g":
                if next == "h" { symbols = i == 0 ? "K" : ""; step = 2 }
                else { symbols = softens(next) ? "J" : "K" }
            case "p":
                if next == "h" { symbols = "F"; step = 2 } else { symbols = "P" }
            case "b": symbols = "P"
            case "k":
                if i == 0 && next == "n" { symbols = "N"; step = 2 } else { symbols = "K" }
            case "q": symbols = "K"
            case "v": symbols = "F"
            case "w":
                if next == "h" { symbols = "W"; step = 2 } else if isVowel(next) { symbols = "W" }
            case "x": symbols = "KS"
            case "z": symbols = "S"
            case "h": break
            default: symbols = c.uppercased()
            }
            out.append(contentsOf: symbols)
            i += step
        }
        return out
    }

    /// Edit distance over the longer length: 0 the same, 1 nothing in common.
    private static func distance(_ a: String, _ b: String) -> Double {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
