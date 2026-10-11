public import Foundation
public import LexiconDomain

/// One Term or one Rule: a line of a Lexicon file, a line typed into the page's
/// Add field, or a row on the page.
public enum LexiconEntry: Sendable, Equatable {
    case term(Term)
    case rule(Rule)
}

/// The import format (spec #36), which dev builds and `lexicon-eval` load too.
/// `scorer/testset` reads the same file (`parse_lexicon`), so the two agree line
/// for line: one entry per line; a line with "->" is a Rule, `heard -> written`,
/// split at its first arrow; any other line is a Term. Each side is trimmed.
/// Blank lines and lines starting with "#" are skipped ("C#" is a Term). A Rule
/// with an empty side is not read, never made a Term. Text is read as NFC, like
/// the text it is matched against.
public struct LexiconFile: Sendable, Equatable {
    public var entries: [LexiconEntry] = []
    /// Lines with an arrow but nothing on one side.
    public var unreadable = 0

    public init(parsing text: String) {
        for line in text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
            guard let arrow = entry.range(of: "->") else {
                entries.append(.term(Term(text: entry)))
                continue
            }
            let heard = entry[..<arrow.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let written = entry[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if heard.isEmpty || written.isEmpty {
                unreadable += 1
            } else {
                entries.append(.rule(Rule(heard: heard, written: written)))
            }
        }
    }

    /// Reads `url` as UTF-8.
    public init(contentsOf url: URL) throws {
        self.init(parsing: try String(contentsOf: url, encoding: .utf8))
    }
}

/// What an import added: Terms and Rules new to the Lexicon, entries it
/// already had (in any case), which an import leaves as they are, and the
/// file's lines that were not read.
public struct ImportCounts: Sendable, Equatable {
    public var terms = 0
    public var rules = 0
    public var duplicates = 0
    public var unreadable = 0
    public init(terms: Int = 0, rules: Int = 0, duplicates: Int = 0, unreadable: Int = 0) {
        self.terms = terms
        self.rules = rules
        self.duplicates = duplicates
        self.unreadable = unreadable
    }
}
