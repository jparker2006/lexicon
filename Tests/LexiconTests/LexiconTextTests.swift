import Foundation
import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

// The words the Lexicon page draws and what its Add field reads. The window
// itself (add, search, delete, import) is checked in the live-app lane.

@Test func aTermsTitleIsItsText() {
    let zorblax = LexiconEntry.term(Term(text: "Zorblax"))
    #expect(LexiconText.title(for: zorblax) == "Zorblax")
}

@Test func aRuleTitleShowsHeardThenWrittenWithAnArrow() {
    let rule = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate"))
    #expect(LexiconText.title(for: rule) == "frob nicate → Frobnicate")
}

@Test func aLearnedRuleTitleStartsWithASparkleAndAnAddedRuleTitleDoesNot() {
    let learned = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate", source: .learned))
    let added = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate", source: .added))
    #expect(LexiconText.title(for: learned) == "✨ frob nicate → Frobnicate")
    #expect(LexiconText.title(for: added) == "frob nicate → Frobnicate")
}

@Test func aBlankSearchMatchesEveryTermAndRule() {
    let zorblax = LexiconEntry.term(Term(text: "Zorblax"))
    let rule = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate"))
    for query in ["", "   "] {
        #expect(LexiconText.matches(zorblax, query))
        #expect(LexiconText.matches(rule, query))
    }
}

@Test func aSearchIgnoresCase() {
    let zorblax = LexiconEntry.term(Term(text: "Zorblax"))
    #expect(LexiconText.matches(zorblax, "zorb"))
    #expect(LexiconText.matches(zorblax, "ZORB"))
}

@Test func aSearchIgnoresAccents() {
    let cafe = LexiconEntry.term(Term(text: "Café"))
    #expect(LexiconText.matches(cafe, "cafe"))
}

@Test func aRuleMatchesOnItsHeardSideAndOnItsWrittenSide() {
    let rule = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate"))
    #expect(LexiconText.matches(rule, "frob nicate"))
    #expect(LexiconText.matches(rule, "frobnicate"))
}

@Test func aSearchThatMatchesNeitherSideFindsNothing() {
    let zorblax = LexiconEntry.term(Term(text: "Zorblax"))
    let rule = LexiconEntry.rule(Rule(heard: "frob nicate", written: "Frobnicate"))
    #expect(!LexiconText.matches(zorblax, "quux"))
    #expect(!LexiconText.matches(rule, "quux"))
    #expect(!LexiconText.matches(zorblax, "Frobnicate"))
}

@Test func termsAndRulesSortTogetherByTheirFirstWordIgnoringCase() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Zorblax")),
        .rule(Rule(heard: "frob nicate", written: "Frobnicate")),
        .term(Term(text: "apple")),
        .term(Term(text: "Banana")),
        .rule(Rule(heard: "codecs", written: "Codex")),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["apple", "Banana", "codecs → Codex", "frob nicate → Frobnicate", "Zorblax"])
}

@Test func numbersInNamesSortAsNumbers() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Item10")),
        .term(Term(text: "Item2")),
        .term(Term(text: "Item1")),
    ]
    let titles = LexiconText.sorted(entries).map { LexiconText.title(for: $0) }
    #expect(titles == ["Item1", "Item2", "Item10"])
}

@Test func aMixedImportSaysWhatWasAddedAndWhatWasLeftAlone() {
    let summary = LexiconText.summary(of: ImportCounts(terms: 6, rules: 4, duplicates: 1, unreadable: 1))
    #expect(summary.message == "Imported 6 Terms and 4 Rules")
    #expect(summary.detail == "1 already in the Lexicon. 1 line not read: a Rule needs both sides, heard -> written.")
}

@Test func aSingleTermOrRuleIsSingularAndHasNoDetail() {
    let term = LexiconText.summary(of: ImportCounts(terms: 1))
    #expect(term.message == "Imported 1 Term")
    #expect(term.detail == "")
    let rule = LexiconText.summary(of: ImportCounts(rules: 1))
    #expect(rule.message == "Imported 1 Rule")
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
    #expect(one.detail == "1 line not read: a Rule needs both sides, heard -> written.")
    let two = LexiconText.summary(of: ImportCounts(unreadable: 2))
    #expect(two.message == "Nothing new to import")
    #expect(two.detail == "2 lines not read: a Rule needs both sides, heard -> written.")
}

@Test func theAddFieldTakesOneTermOrOneRuleTypedEitherWay() {
    #expect(LexiconText.entry(typed: "  Zorblax ") == .term(Term(text: "Zorblax")))
    #expect(LexiconText.entry(typed: "frob nicate -> Frobnicate") == .rule(Rule(heard: "frob nicate", written: "Frobnicate")))
    #expect(LexiconText.entry(typed: "frob nicate → Frobnicate") == .rule(Rule(heard: "frob nicate", written: "Frobnicate")))
    for nothing in ["", "   ", "# a comment", "-> Frobnicate", "frob nicate ->"] {
        #expect(LexiconText.entry(typed: nothing) == nil, "\(nothing)")
    }
}

@Test func anEntryJustAddedFindsItsRowWhateverCaseAndSpacingTheStoreKept() {
    let typed = LexiconEntry.rule(Rule(heard: "frob  nicate", written: "Frobnicate"))
    #expect(LexiconText.isSame(.rule(Rule(heard: "Frob nicate", written: "FROBNICATE")), typed))
    #expect(LexiconText.isSame(.term(Term(text: "zorblax")), .term(Term(text: "Zorblax"))))
    #expect(!LexiconText.isSame(.term(Term(text: "frob nicate")), typed))
    #expect(!LexiconText.isSame(.term(Term(text: "Zorblax")), .term(Term(text: "Vexmo"))))
}
