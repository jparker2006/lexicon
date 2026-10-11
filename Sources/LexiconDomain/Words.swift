import Foundation

/// A word or name the Lexicon always writes one exact way: "gstack", "ELI5",
/// "CLAUDE.md". Variants that differ only in case, spaces, hyphens or
/// spelled-out numbers fold to it in code (`RuleSet`).
public struct Term: Sendable, Hashable, Codable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// "When you hear X, write Y", added by Jake or learned from a Fix he confirmed.
public struct Rule: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Codable, CaseIterable { case added, learned }
    public var heard: String
    public var written: String
    public var source: Source
    public init(heard: String, written: String, source: Source = .added) {
        self.heard = heard
        self.written = written
        self.source = source
    }
}

/// Every Rule and Term compiled for one Dictation: Cleanup's step 2, run in
/// code on every Dictation in every mode, before any AI cleanup. An immutable
/// snapshot taken at fn-down, so a Rule added mid-Dictation never changes text
/// already being produced.
///
/// Matching semantics live here and only here. Words are split by whitespace,
/// or by a hyphen between letters or digits. Punctuation at a word's edges stays
/// where it is, and so does a possessive "'s"; punctuation or a line break
/// between two words ends a match.
///   - A Rule matches its `heard` words, case-insensitively and whole words
///     only, and writes `written` exactly.
///   - A Term matches any run of words that spells it once case, spaces,
///     hyphens and spelled-out numbers are set aside ("G stack", "ELI five"),
///     unless every word in the run is plain English ("work tree", "linear").
///     Those need a Rule, so a Term can never rewrite an ordinary sentence.
///   - At each word the longest Rule wins, then the longest Term. Output is
///     never scanned again.
public struct RuleSet: Sendable {
    public static let empty = RuleSet([])

    struct Compiled: Sendable {
        let heard: [String]
        let written: String
    }

    /// Rules by the lowercased first word of `heard`, longest first.
    let rules: [String: [Compiled]]
    /// Terms by fold key, plus every prefix of every key so a scan stops early.
    let terms: [String: String]
    let prefixes: Set<String>
    /// Lowercased plain-English words: at least every word spelled inside a Term.
    let english: Set<String>
    /// Every Term and every Rule's written side, exactly as written.
    let written: Set<String>

    /// Rules only, no folding.
    public init(_ rules: [Rule]) { self.init(rules: rules, terms: [], english: []) }

    /// `english` decides which words are plain English. Only the words in
    /// `wordsInside(terms)` are ever looked up; a word missing from it counts as
    /// not English, so the caller must err toward including a word.
    public init(rules: [Rule], terms: [Term], english: Set<String>) {
        var byFirst: [String: [Compiled]] = [:]
        for rule in rules {
            let heard = Self.words(in: rule.heard).map(\.lower)
            guard let first = heard.first, !heard.contains("") else { continue }
            byFirst[first, default: []].append(Compiled(heard: heard, written: rule.written))
        }
        self.rules = byFirst.mapValues { $0.sorted { $0.heard.count > $1.heard.count } }

        var keyed: [String: String] = [:]
        var prefixes = Set<String>()
        for term in terms {
            let key = Self.key(of: term.text)
            guard !key.isEmpty else { continue }
            keyed[key] = term.text
            var prefix = ""
            for character in key {
                prefix.append(character)
                prefixes.insert(prefix)
            }
        }
        self.terms = keyed
        self.prefixes = prefixes
        self.english = english
        // A written side's first word too: "npm run" keeps "npm" lowercase at a sentence start.
        let writtenForms = terms.map(\.text) + rules.map(\.written)
        self.written = Set(writtenForms + writtenForms.compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    public var isEmpty: Bool { rules.isEmpty && terms.isEmpty }

    /// Pure, microseconds.
    public func apply(to text: String) -> String {
        guard !isEmpty else { return text }
        let words = Self.words(in: text)
        var out = ""
        var copied = text.startIndex
        var i = 0
        while i < words.count {
            guard let (count, replacement) = rule(at: i, in: words) ?? term(at: i, in: words) else {
                i += 1
                continue
            }
            out += text[copied..<words[i].core.lowerBound]
            out += replacement
            copied = words[i + count - 1].core.upperBound
            i += count
        }
        return out + text[copied...]
    }

    /// True when `word`, edge punctuation aside, is exactly a Term or a Rule's
    /// written side. Later passes must not change its case.
    public func isWritten(_ word: some StringProtocol) -> Bool {
        guard !written.isEmpty else { return false }
        return written.contains(String(Self.core(of: Substring(word))))
    }

    /// Every lowercased, letters-only word that a variant of `terms` can
    /// contain: the words whose plainness `english` must answer for.
    public static func wordsInside(_ terms: [Term]) -> Set<String> {
        var found = Set<String>()
        for term in terms {
            for run in key(of: term.text).split(whereSeparator: { !$0.isLetter }) {
                let letters = Array(run)
                for i in letters.indices {
                    for j in i..<letters.count { found.insert(String(letters[i...j])) }
                }
            }
        }
        return found
    }

    private func rule(at start: Int, in words: [Word]) -> (count: Int, written: String)? {
        guard let candidates = rules[words[start].lower] else { return nil }
        candidates: for candidate in candidates {
            let count = candidate.heard.count
            guard start + count <= words.count else { continue }
            for k in 1..<count where !words[start + k - 1].joinsNext || words[start + k].lower != candidate.heard[k] {
                continue candidates
            }
            return (count, candidate.written)
        }
        return nil
    }

    private func term(at start: Int, in words: [Word]) -> (count: Int, written: String)? {
        var key = ""
        var plain = true
        var found: (count: Int, written: String)?
        for end in start..<words.count {
            let word = words[end]
            guard !word.lower.isEmpty else { break }
            key += Self.numbers[word.lower] ?? word.lower
            guard prefixes.contains(key) else { break }
            plain = plain && (Self.numbers[word.lower] != nil || english.contains(word.lower))
            if !plain, let term = terms[key] { found = (end - start + 1, term) }
            guard word.joinsNext else { break }
        }
        return found
    }

    /// A Term's fold key: its words lowercased, spelled-out numbers as digits, joined.
    static func key(of text: String) -> String {
        words(in: text).map { numbers[$0.lower] ?? $0.lower }.joined()
    }

    static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
    ]

    struct Word {
        /// The word without its edge punctuation or possessive. Empty for a piece that is all punctuation.
        let core: Range<String.Index>
        let lower: String
        /// Only spaces, tabs or one hyphen sit between this core and the next word's.
        var joinsNext = false
    }

    /// `piece` without its edge punctuation or a final possessive: "(Supabase's)." -> "Supabase".
    static func core(of piece: Substring) -> Substring {
        var core = piece
        while core.first?.isEdgePunctuation == true { core.removeFirst() }
        while core.last?.isEdgePunctuation == true { core.removeLast() }
        for possessive in ["'s", "\u{2019}s"] where core.count > 2 && core.hasSuffix(possessive) {
            core.removeLast(2)
        }
        return core
    }

    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var lastCoreEndsPiece = false
        var pieceStart: String.Index?
        var startJoins = false     // the gap before the current piece allows a join
        var gapHasNewline = false

        func close(_ end: String.Index) {
            guard let start = pieceStart else { return }
            pieceStart = nil
            let core = Self.core(of: text[start..<end])
            let (lower, upper) = (core.startIndex, core.endIndex)
            if !words.isEmpty {
                words[words.count - 1].joinsNext = startJoins && lastCoreEndsPiece && lower == start && upper > lower
            }
            // A curly apostrophe matches a straight one: "don\u{2019}t" is "don't".
            let folded = text[lower..<upper].lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            words.append(Word(core: lower..<upper, lower: folded))
            lastCoreEndsPiece = upper == end
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isWhitespace {
                close(index)
                if character.isNewline { gapHasNewline = true }
            } else if character == "-", let start = pieceStart, start < index,
                      text[text.index(before: index)].isLetterOrDigit, next < text.endIndex,
                      text[next].isLetterOrDigit {
                close(index)
                startJoins = true
                pieceStart = next
            } else if pieceStart == nil {
                pieceStart = index
                startJoins = !gapHasNewline
                gapHasNewline = false
            }
            index = next
        }
        close(text.endIndex)
        return words
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
    var isEdgePunctuation: Bool { ".,!?;:\"'()[]{}\u{201C}\u{201D}\u{2018}\u{2019}\u{2026}".contains(self) }
}

/// What Lexicon knows about where Jake is dictating. Gathered at fn-down from
/// the frontmost app (no screenshots, ever: D5).
public struct AppContext: Sendable, Hashable, Codable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    /// Current project, when known (Claude Code hook `cwd`, terminal title). #21 decides more.
    public var workingDirectory: String?
    public init(bundleID: String?, appName: String?, windowTitle: String?, workingDirectory: String?) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.workingDirectory = workingDirectory
    }
    public static let unknown = AppContext(bundleID: nil, appName: nil, windowTitle: nil, workingDirectory: nil)
}
