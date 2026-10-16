import Foundation
import LexiconDomain
import WordStore

/// A page row keeps its storage records so Delete removes the forms it shows.
struct DictionaryEntry {
    let spelling: String
    let records: [LexiconEntry]

    var forms: [Rule] {
        records.compactMap { if case .rule(let rule) = $0 { rule } else { nil } }
            .sorted { LexiconText.ordered($0.heard, $1.heard) }
    }
}

/// The words the Lexicon page draws, apart from AppKit so tests can read them.
enum LexiconText {
    static let importFailure = (
        message: "Couldn't import that file",
        detail: "Import reads one spelling or heard-as form per line, heard -> written. Nothing was added."
    )

    static func title(for entry: DictionaryEntry) -> String {
        let forms = entry.forms.map { ($0.source == .learned ? "✨ " : "") + $0.heard }
        return entry.spelling + (forms.isEmpty ? "" : " (heard as: \(forms.joined(separator: ", ")))")
    }

    /// One heard-as form's line under its spelling.
    static func formLine(_ rule: Rule) -> String {
        "heard as: " + (rule.source == .learned ? "✨ " : "") + rule.heard
    }

    /// What the Add field holds: exactly one line of the import format, or nil.
    /// A heard-as line typed with "→" reads as one typed with "->".
    static func entry(typed text: String) -> LexiconEntry? {
        let file = LexiconFile(parsing: text.replacingOccurrences(of: "→", with: "->"))
        return file.entries.count == 1 && file.unreadable == 0 ? file.entries.first : nil
    }

    /// A match on any form returns the whole row; searching never changes grouping.
    static func matches(_ entry: DictionaryEntry, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return entry.spelling.localizedStandardContains(query)
            || entry.forms.contains { $0.heard.localizedStandardContains(query) }
    }

    static func sorted(_ entries: [LexiconEntry]) -> [DictionaryEntry] {
        // String equality folds canonically equivalent Unicode. Bytes keep every
        // exact stored spelling separate without changing the store's own keys.
        let grouped = Dictionary(grouping: entries) { entry in
            Array(spelling(of: entry).utf8)
        }
        return grouped.values.compactMap { records in
            records.first.map { DictionaryEntry(spelling: spelling(of: $0), records: records) }
        }.sorted { ordered($0.spelling, $1.spelling) }
    }

    static func ordered(_ a: String, _ b: String) -> Bool {
        let comparison = a.localizedStandardCompare(b)
        return comparison == .orderedSame ? a.utf8.lexicographicallyPrecedes(b.utf8) : comparison == .orderedAscending
    }

    private static func spelling(of entry: LexiconEntry) -> String {
        switch entry {
        case .term(let term): term.text
        case .rule(let rule): rule.written
        }
    }

    /// The same Term or the same heard side, in any case or spacing: the row an
    /// entry just added landed on, whatever the store kept of how it was typed.
    static func contains(_ group: DictionaryEntry, _ entry: LexiconEntry) -> Bool {
        group.records.contains { isSame($0, entry) }
    }

    private static func isSame(_ a: LexiconEntry, _ b: LexiconEntry) -> Bool {
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
    static func summary(of counts: ImportCounts) -> (message: String, detail: String) {
        let unreadable = counts.unreadable
        let added = [counted(counts.terms, "spelling"), counted(counts.rules, "heard-as form")].compactMap { $0 }
        let message = added.isEmpty ? "Nothing new to import" : "Imported " + added.joined(separator: " and ")
        let detail = [
            counts.duplicates > 0 ? "\(counts.duplicates) already in the Lexicon." : nil,
            unreadable > 0 ? "\(unreadable) \(unreadable == 1 ? "line" : "lines") not read: a heard-as form needs both sides, heard -> written." : nil,
        ].compactMap { $0 }.joined(separator: " ")
        return (message, detail)
    }

    private static func counted(_ count: Int, _ noun: String) -> String? {
        count == 0 ? nil : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}
