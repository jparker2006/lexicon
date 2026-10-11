import Foundation
import LexiconDomain
import WordStore

/// The words the Lexicon page draws, apart from AppKit so tests can read them.
enum LexiconText {
    /// "gstack", or a Rule as "codecs → Codex"; ✨ in front of anything learned.
    static func title(for entry: LexiconEntry) -> String {
        switch entry {
        case .term(let term): term.text
        case .rule(let rule): (rule.source == .learned ? "✨ " : "") + "\(rule.heard) → \(rule.written)"
        }
    }

    /// What the Add field holds: exactly one line of the import format, or nil.
    /// The page shows Rules with "→", so a Rule typed the way it is shown is one too.
    static func entry(typed text: String) -> LexiconEntry? {
        let file = LexiconFile(parsing: text.replacingOccurrences(of: "→", with: "->"))
        return file.entries.count == 1 && file.unreadable == 0 ? file.entries.first : nil
    }

    /// Search: a plain match, ignoring case and accents, on a Term or on either side of a Rule.
    static func matches(_ entry: LexiconEntry, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return switch entry {
        case .term(let term): term.text.localizedStandardContains(query)
        case .rule(let rule): rule.heard.localizedStandardContains(query) || rule.written.localizedStandardContains(query)
        }
    }

    /// One list, Terms and Rules together, in the order Finder sorts names: a
    /// Rule sits where its heard side would, so "codecs → Codex" is under C.
    static func sorted(_ entries: [LexiconEntry]) -> [LexiconEntry] {
        entries.sorted { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
    }

    /// The same Term or the same heard side, in any case or spacing: the row an
    /// entry just added landed on, whatever the store kept of how it was typed.
    static func isSame(_ a: LexiconEntry, _ b: LexiconEntry) -> Bool {
        switch (a, b) {
        case (.term, .term), (.rule, .rule):
            key(a).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .caseInsensitiveCompare(key(b).split(whereSeparator: \.isWhitespace).joined(separator: " ")) == .orderedSame
        default: false
        }
    }

    private static func key(_ entry: LexiconEntry) -> String {
        switch entry {
        case .term(let term): term.text
        case .rule(let rule): rule.heard
        }
    }

    /// The import alert: what was added, then what was left as it was.
    static func summary(of counts: ImportCounts, unreadable: Int) -> (message: String, detail: String) {
        let added = [counted(counts.terms, "Term"), counted(counts.rules, "Rule")].compactMap { $0 }
        let message = added.isEmpty ? "Nothing new to import" : "Imported " + added.joined(separator: " and ")
        let detail = [
            counts.duplicates > 0 ? "\(counts.duplicates) already in the Lexicon." : nil,
            unreadable > 0 ? "\(unreadable) \(unreadable == 1 ? "line" : "lines") not read: a Rule needs both sides, heard -> written." : nil,
        ].compactMap { $0 }.joined(separator: " ")
        return (message, detail)
    }

    private static func counted(_ count: Int, _ noun: String) -> String? {
        count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
