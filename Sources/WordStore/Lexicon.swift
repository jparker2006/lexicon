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
    /// The current repo's code Terms, in the order selection takes them
    /// (`CodeTerms`). Held in memory, never stored.
    public private(set) var codeTerms: [Term] = []
    /// Every Term, then every Rule, in one read: what the Lexicon page lists.
    public var entries: [LexiconEntry] { terms.map(LexiconEntry.term) + rules.map(LexiconEntry.rule) }
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
    /// Under 1 ms.
    public func forDictation(in context: AppContext) -> DictationWords {
        // TODO(#73): select up to `Preferences.cleanupTerms` Terms for the models.
        DictationWords(terms: [], rules: compiled)
    }

    /// The same text again, in any case, replaces the Term's spelling: still one Term.
    public func add(_ term: Term) throws {
        guard let text = Self.stored(term) else { return }
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
        guard let (heard, written) = Self.stored(rule) else { return }
        try database.execute("""
            INSERT INTO rule (heard, written, source) VALUES (?, ?, ?)
            ON CONFLICT (heard) DO UPDATE SET heard = excluded.heard, written = excluded.written, source = excluded.source
            """, [.text(heard), .text(written), .text(rule.source.rawValue)])
        try reload()
    }

    /// Removes the Rule for `rule.heard`, whatever it writes.
    public func remove(_ rule: Rule) throws {
        try database.execute("DELETE FROM rule WHERE heard = ?", [.text(Self.heard(of: rule))])
        try reload()
    }

    /// The page's Import: reads the file here, off the main thread (a file in
    /// iCloud may have to download first), then adds it as below.
    public func add(contentsOf url: URL) throws -> ImportCounts {
        let file = try LexiconFile(contentsOf: url)
        var counts = try add(file.entries)
        counts.unreadable = file.unreadable
        return counts
    }

    /// Import: every entry the Lexicon doesn't have yet, in one transaction and
    /// one recompile, so the system word list is read once for the whole file. An entry
    /// it already has, in any case, stays as it is: importing a file twice, or
    /// over Jake's own edits, changes nothing. (Add, above, replaces instead:
    /// typing a spelling means Jake wants that spelling.)
    public func add(_ entries: [LexiconEntry]) throws -> ImportCounts {
        var counts = ImportCounts()
        try database.transaction { database in
            for entry in entries {
                switch entry {
                case .term(let term):
                    guard let text = Self.stored(term) else { continue }
                    try database.execute("INSERT INTO term (text) VALUES (?) ON CONFLICT (text) DO NOTHING", [.text(text)])
                    if database.changes > 0 { counts.terms += 1 } else { counts.duplicates += 1 }
                case .rule(let rule):
                    guard let (heard, written) = Self.stored(rule) else { continue }
                    try database.execute("INSERT INTO rule (heard, written, source) VALUES (?, ?, ?) ON CONFLICT (heard) DO NOTHING",
                                         [.text(heard), .text(written), .text(rule.source.rawValue)])
                    if database.changes > 0 { counts.rules += 1 } else { counts.duplicates += 1 }
                }
            }
        }
        try reload()
        return counts
    }

    /// `CodeTerms` hands over the current repo's code Terms whenever they change.
    func useCodeTerms(_ terms: [Term]) { codeTerms = terms }

    /// Rereads both tables and recompiles. The word list is read again only when
    /// the Terms changed: plainness is a question about the words inside Terms.
    private func reload() throws {
        let (terms, rules) = try Self.load(database)
        if terms != self.terms { english = EnglishWords.among(RuleSet.wordsInside(terms)) }
        (self.terms, self.rules) = (terms, rules)
        compiled = RuleSet(rules: rules, terms: terms, english: english)
    }

    /// A Term as stored: trimmed, nil when nothing is left.
    private static func stored(_ term: Term) -> String? {
        let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// A Rule as stored: `heard` with its spaces collapsed, `written` trimmed;
    /// nil when either is empty.
    private static func stored(_ rule: Rule) -> (heard: String, written: String)? {
        let heard = heard(of: rule)
        let written = rule.written.trimmingCharacters(in: .whitespacesAndNewlines)
        return heard.isEmpty || written.isEmpty ? nil : (heard, written)
    }

    private static func heard(of rule: Rule) -> String {
        rule.heard.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
