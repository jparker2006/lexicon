import Foundation
import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

// The dictionary rows the Lexicon page draws and what its Add field reads.
// The window itself (add, search, delete, import) is checked in the live-app lane.

@Test func aDictionaryEntryShowsItsWrittenSpellingAndAllHeardForms() {
    let entries: [LexiconEntry] = [
        .rule(Rule(heard: "super bass", written: "Supabase")),
        .term(Term(text: "Supabase")),
        .rule(Rule(heard: "super base", written: "Supabase")),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["Supabase (heard as: super base, super bass)"])
}

@Test func aLearnedMarkStaysBesideItsOwnHeardForm() {
    let entries: [LexiconEntry] = [
        .rule(Rule(heard: "frop nicate", written: "Frobnicate")),
        .rule(Rule(heard: "frob nicate", written: "Frobnicate", source: .learned)),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["Frobnicate (heard as: ✨ frob nicate, frop nicate)"])
}

@Test func aTemporaryLexiconProjectsOneEntryAndKeepsBothRulesWorking() async throws {
    let lexicon = try Lexicon(paths: .temporary())
    try await lexicon.add(Term(text: "Supabase"))
    try await lexicon.add(Rule(heard: "super base", written: "Supabase", source: .learned))
    try await lexicon.add(Rule(heard: "super bass", written: "Supabase"))

    let titles = LexiconText.sorted(await lexicon.entries).map { LexiconText.title(for: $0) }
    #expect(await lexicon.entries.count == 3)
    #expect(titles == ["Supabase (heard as: ✨ super base, super bass)"])

    let rules = await lexicon.forDictation(in: .unknown).rules
    #expect(rules.apply(to: "super base and super bass") == "Supabase and Supabase")
}

@Test func entriesGroupByExactWrittenValueWithoutCaseOrAccentMerging() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Codex")),
        .rule(Rule(heard: "codecs", written: "Codex")),
        .term(Term(text: "CODEX")),
        .rule(Rule(heard: "code ex", written: "CODEX")),
        .term(Term(text: "Cafe")),
        .rule(Rule(heard: "coffee", written: "Cafe")),
        .term(Term(text: "Café")),
        .rule(Rule(heard: "ka fay", written: "Café")),
    ]
    let groups = LexiconText.sorted(entries)
    let titles = groups.map { LexiconText.title(for: $0) }

    #expect(groups.count == 4)
    #expect(Set(titles) == Set([
        "Codex (heard as: codecs)",
        "CODEX (heard as: code ex)",
        "Cafe (heard as: coffee)",
        "Café (heard as: ka fay)",
    ]))
    #expect(groups.filter { LexiconText.matches($0, "codex") }.count == 2)
    #expect(groups.filter { LexiconText.matches($0, "cafe") }.count == 2)
}

@Test func dictionaryEntriesSortByWrittenSpelling() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Zorblax")),
        .rule(Rule(heard: "zulu", written: "Frobnicate")),
        .term(Term(text: "apple")),
        .term(Term(text: "Banana")),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["apple", "Banana", "Frobnicate (heard as: zulu)", "Zorblax"])
}

@Test func numbersInWrittenSpellingsSortAsNumbers() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Item10")),
        .term(Term(text: "Item2")),
        .term(Term(text: "Item1")),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["Item1", "Item2", "Item10"])
}

@Test func searchMatchesTheWrittenSpellingAndEveryHeardForm() {
    let groups = LexiconText.sorted([
        .rule(Rule(heard: "super base", written: "Supabase")),
        .rule(Rule(heard: "cafe latte", written: "Café Latte")),
    ])

    #expect(groups.count == 2)
    for query in ["", "   "] {
        #expect(groups.filter { LexiconText.matches($0, query) }.count == groups.count)
    }
    #expect(groups.filter { LexiconText.matches($0, "SUPABASE") }.count == 1)
    #expect(groups.filter { LexiconText.matches($0, "SUPER BASE") }.count == 1)
    #expect(groups.filter { LexiconText.matches($0, "cafe latte") }.count == 1)
    #expect(groups.filter { LexiconText.matches($0, "cafe") }.count == 1)
    #expect(groups.filter { LexiconText.matches($0, "quux") }.isEmpty)
}

@Test func aMixedImportSaysWhatWasAddedAndWhatWasLeftAlone() {
    let summary = LexiconText.summary(of: ImportCounts(terms: 6, rules: 4, duplicates: 1, unreadable: 1))
    #expect(summary.message == "Imported 6 spellings and 4 heard-as forms")
    #expect(summary.detail == "1 already in the Lexicon. 1 line not read: a heard-as form needs both sides, heard -> written.")
}

@Test func aSingleTermOrRuleIsSingularAndHasNoDetail() {
    let term = LexiconText.summary(of: ImportCounts(terms: 1))
    #expect(term.message == "Imported 1 spelling")
    #expect(term.detail == "")
    let rule = LexiconText.summary(of: ImportCounts(rules: 1))
    #expect(rule.message == "Imported 1 heard-as form")
    #expect(rule.detail == "")
}

@Test func anImportThatAddsNothingSaysSoAndCountsWhatWasAlreadyThere() {
    let summary = LexiconText.summary(of: ImportCounts(duplicates: 11))
    #expect(summary.message == "Nothing new to import")
    #expect(summary.detail == "11 already in the Lexicon.")
}

@Test func unreadableLinesAreCountedInTheDetailAndOneLineIsSingular() {
    let one = LexiconText.summary(of: ImportCounts(unreadable: 1))
    #expect(one.message == "Nothing new to import")
    #expect(one.detail == "1 line not read: a heard-as form needs both sides, heard -> written.")
    let two = LexiconText.summary(of: ImportCounts(unreadable: 2))
    #expect(two.message == "Nothing new to import")
    #expect(two.detail == "2 lines not read: a heard-as form needs both sides, heard -> written.")
}

@Test func importFailureExplainsSpellingsAndHeardAsForms() {
    let failure = LexiconText.importFailure
    #expect(failure.message == "Couldn't import that file")
    #expect(failure.detail == "Import reads one spelling or heard-as form per line, heard -> written. Nothing was added.")

    let copy = failure.message + " " + failure.detail
    #expect(!copy.localizedCaseInsensitiveContains("term"))
    #expect(!copy.localizedCaseInsensitiveContains("rule"))
}

@Test func theAddFieldTakesOneTermOrOneRuleTypedEitherWay() {
    #expect(LexiconText.entry(typed: "  Zorblax ") == .term(Term(text: "Zorblax")))
    #expect(LexiconText.entry(typed: "frob nicate -> Frobnicate") == .rule(Rule(heard: "frob nicate", written: "Frobnicate")))
    #expect(LexiconText.entry(typed: "frob nicate → Frobnicate") == .rule(Rule(heard: "frob nicate", written: "Frobnicate")))
    for nothing in ["", "   ", "# a comment", "-> Frobnicate", "frob nicate ->"] {
        #expect(LexiconText.entry(typed: nothing) == nil, "\(nothing)")
    }
}
