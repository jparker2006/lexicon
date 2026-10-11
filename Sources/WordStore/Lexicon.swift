public import Foundation
public import LexiconDomain
import SQLiteKit

/// The Lexicon: Jake's personal word store (terms, names, code terms, Rules).
/// Sole owner of `lexicon.sqlite`. What goes in it and code scanning are #21;
/// this module is where those answers land.
///
/// Hides: storage, the in-memory term index (loaded at launch, so per-Dictation
/// selection is a sub-millisecond lookup on the fn-down path), relevance ranking
/// (current repo, active app, recent Fixes, names), phonetic matching for close
/// calls and Re-speak candidates.
public actor Lexicon {
    /// Opens `<root>/lexicon.sqlite` (this module names it) and loads the term index.
    /// Until the store lands (#70) it opens nothing: M0 to M2 run with no Terms or Rules.
    public init(paths: AppPaths) throws {}

    /// fn-down: up to `Preferences.cleanupTerms` most relevant Terms for this
    /// context, best first (never the whole Lexicon: #10), plus a compiled
    /// snapshot of every Rule. Speech takes the first `speechTerms`. Under 1 ms.
    public func forDictation(in context: AppContext) -> DictationWords { .empty }

    /// Spans of `text` that sound like a Lexicon term with no Rule covering them.
    /// Feeds Jev close calls (#10) and Re-speak candidate search (M4).
    public func closeCalls(in text: String) -> [CloseCall] { fatalError("not implemented") }

    /// From a confirmed Fix. Idempotent: the same Rule twice is one Rule.
    public func addRule(_ rule: Rule, from fix: FixID) { fatalError("not implemented") }
    public func removeRule(_ rule: Rule) { fatalError("not implemented") }

    /// Context Lexicon may use (D5): a project directory seen via the Claude Code
    /// hook or a terminal title. Scanning it for code terms is #21.
    public func noteProject(_ directory: URL) { fatalError("not implemented") }
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
    /// Append-only. Rules storage details are #21's; this is the starting point.
    static let migrations: [String] = [
        """
        CREATE TABLE term (
          id INTEGER PRIMARY KEY,
          text TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,            -- Term.Kind raw value
          source TEXT,                   -- manual | fix | code-scan | contacts
          weight REAL NOT NULL DEFAULT 1,
          last_used_at INTEGER
        );
        CREATE TABLE rule (
          id INTEGER PRIMARY KEY,
          heard TEXT NOT NULL,
          written TEXT NOT NULL,
          source_fix TEXT,               -- FixID in history.sqlite (no cross-file FK)
          created_at INTEGER NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          UNIQUE (heard, written)
        );
        """,
    ]
}
