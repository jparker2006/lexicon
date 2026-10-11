public import Foundation
public import LexiconDomain
import SQLiteKit

/// The Lexicon: Jake's Terms and Rules. Sole owner of `lexicon.sqlite`.
///
/// Hides: storage, and the compiled `RuleSet` (Rules plus Term folding), rebuilt
/// whenever the Lexicon changes so a Dictation's fn-down only copies a value.
public actor Lexicon {
    private let database: Database
    public private(set) var terms: [Term] = []
    public private(set) var rules: [Rule] = []
    /// The plain-English words among those inside Terms (`EnglishWords`).
    private var english = Set<String>()
    private var compiled = RuleSet.empty

    /// Opens `<root>/lexicon.sqlite`, creating it, and compiles the Rules and folding.
    public init(paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        database = try Database(at: paths.root.appending(path: "lexicon.sqlite"), mode: .readWrite,
                                migrations: LexiconSchema.migrations)
        let (terms, rules) = try Self.load(database)
        english = EnglishWords.among(RuleSet.wordsInside(terms))
        (self.terms, self.rules) = (terms, rules)
        compiled = RuleSet(rules: rules, terms: terms, english: english)
    }

    /// fn-down: this Dictation's words, a snapshot that later changes never touch.
    /// Under 1 ms. `terms` stays empty until per-Dictation selection lands (#73).
    public func forDictation(in context: AppContext) -> DictationWords {
        DictationWords(terms: [], rules: compiled)
    }

    /// The same text again, in any case, replaces the Term's spelling: still one Term.
    public func add(_ term: Term) throws {
        let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try database.execute("INSERT INTO term (text) VALUES (?) ON CONFLICT (text) DO UPDATE SET text = excluded.text",
                             [.text(text)])
        try reload()
    }

    public func remove(_ term: Term) throws {
        try database.execute("DELETE FROM term WHERE text = ?", [.text(term.text)])
        try reload()
    }

    /// The same `heard` again, in any case, replaces the Rule: still one Rule.
    public func add(_ rule: Rule) throws {
        let heard = rule.heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let written = rule.written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else { return }
        try database.execute("""
            INSERT INTO rule (heard, written, source) VALUES (?, ?, ?)
            ON CONFLICT (heard) DO UPDATE SET heard = excluded.heard, written = excluded.written, source = excluded.source
            """, [.text(heard), .text(written), .text(rule.source.rawValue)])
        try reload()
    }

    /// Removes the Rule for `rule.heard`, whatever it writes.
    public func remove(_ rule: Rule) throws {
        let heard = rule.heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        try database.execute("DELETE FROM rule WHERE heard = ?", [.text(heard)])
        try reload()
    }

    /// Spans of `text` that sound like a Lexicon term with no Rule covering them.
    /// Feeds Re-speak candidate search (M4).
    public func closeCalls(in text: String) -> [CloseCall] { fatalError("not implemented") }

    /// Context Lexicon may use (D5): a project directory seen via the Claude Code
    /// hook or a terminal title. Scanning it for code terms is #21.
    public func noteProject(_ directory: URL) { fatalError("not implemented") }

    /// Rereads both tables and recompiles. The word list is read again only when
    /// the Terms changed: plainness is a question about the words inside Terms.
    private func reload() throws {
        let (terms, rules) = try Self.load(database)
        if terms != self.terms { english = EnglishWords.among(RuleSet.wordsInside(terms)) }
        (self.terms, self.rules) = (terms, rules)
        compiled = RuleSet(rules: rules, terms: terms, english: english)
    }

    private static func load(_ database: Database) throws -> ([Term], [Rule]) {
        let terms = try database.query("SELECT text FROM term ORDER BY id").compactMap { $0.text(0) }.map(Term.init)
        let rules = try database.query("SELECT heard, written, source FROM rule ORDER BY id").compactMap { row -> Rule? in
            guard let heard = row.text(0), let written = row.text(1),
                  let source = row.text(2).flatMap(Rule.Source.init(rawValue:)) else { return nil }
            return Rule(heard: heard, written: written, source: source)
        }
        return (terms, rules)
    }
}

public struct DictationWords: Sendable {
    public let terms: [Term]
    public let rules: RuleSet
    public static let empty = DictationWords(terms: [], rules: .empty)
    public init(terms: [Term], rules: RuleSet) {
        self.terms = terms
        self.rules = rules
    }
}

public struct CloseCall: Sendable, Hashable {
    /// UTF-16 offsets into the text that was searched.
    public let location: Int
    public let length: Int
    public let heard: String
    public let term: Term
    /// 0 = identical sound. Threshold is tuned on the Test set.
    public let distance: Double
}

enum LexiconSchema {
    /// Append-only once shipped. Uniqueness is case-insensitive because matching is:
    /// "codecs" and "Codecs" are one Rule, "gstack" and "GStack" one Term.
    static let migrations: [String] = [
        """
        CREATE TABLE term (
          id INTEGER PRIMARY KEY,
          text TEXT NOT NULL UNIQUE COLLATE NOCASE
        );
        CREATE TABLE rule (
          id INTEGER PRIMARY KEY,
          heard TEXT NOT NULL UNIQUE COLLATE NOCASE,
          written TEXT NOT NULL,
          source TEXT NOT NULL CHECK (source IN ('added', 'learned'))
        );
        """,
    ]
}
