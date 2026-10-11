import Foundation
import Testing
import LexiconDomain
import WordStore

// Import (#71): a text file with one entry per line, a bare line a Term and
// `heard -> written` a Rule. The format is the one `scorer/testset` reads
// (`parse_lexicon`), so the cases below mirror its tests. The file is the public
// sample in scorer/fixtures, made-up words only, never Jake's starter Lexicon.

private let sample = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "scorer/fixtures/sample-lexicon.txt")

private func parsed(_ text: String) -> [LexiconEntry] { LexiconFile(parsing: text).entries }

@Test func aLineWithAnArrowIsARuleAndAnyOtherLineATerm() {
    #expect(parsed("Supabase\nuse effect -> useEffect\n")
        == [.term(Term(text: "Supabase")), .rule(Rule(heard: "use effect", written: "useEffect"))])
}

@Test func blankLinesAndCommentsAreSkippedButAHashInsideATermIsNot() {
    #expect(parsed("\n# a comment\n   \n  # an indented comment\nkubectl\r\n") == [.term(Term(text: "kubectl"))])
    #expect(parsed("C#\n#C++\n") == [.term(Term(text: "C#"))])
}

@Test func eachSideIsTrimmedAndOnlyTheFirstArrowSplits() {
    #expect(parsed("  kubectl  \n  cube cuddle  ->   kubectl  \n")
        == [.term(Term(text: "kubectl")), .rule(Rule(heard: "cube cuddle", written: "kubectl"))])
    #expect(parsed("a -> b -> c") == [.rule(Rule(heard: "a", written: "b -> c"))])
}

@Test func aRuleWithAnEmptySideIsNotReadNorMadeATerm() {
    let file = LexiconFile(parsing: "-> orphan\nempty ->\n  ->  \n")
    #expect(file.entries.isEmpty)
    #expect(file.unreadable == 3)
}

@Test func textIsReadAsNFC() throws {
    // "e" plus a combining accent is stored as one "é", so an entry typed either way is one entry.
    let entry = try #require(parsed("Beyonce\u{301} -> Beyonce").first)
    guard case .rule(let rule) = entry else { Issue.record("not a Rule"); return }
    #expect(rule.heard.unicodeScalars.map(\.value) == "Beyonc\u{E9}".unicodeScalars.map(\.value))
}

@Test func importingTheSampleCreatesItsTermsAndRules() async throws {
    let store = try Lexicon(paths: .temporary())
    let file = try LexiconFile(contentsOf: sample)
    #expect(file.unreadable == 1)

    let added = try await store.add(file.entries)

    #expect(added == ImportCounts(terms: 6, rules: 4, duplicates: 1))
    #expect(await store.terms.map(\.text) == ["Zorblax", "QuuxKit", "flimDB", "snorp-ctl", "Vexmo", "Trellium.md"])
    #expect(await store.rules == [
        Rule(heard: "frob nicate", written: "Frobnicate"), Rule(heard: "quux kit", written: "QuuxKit"),
        Rule(heard: "slash zap", written: "/zap"), Rule(heard: "cube nector", written: "kubenector"),
    ])
    let rules = await store.forDictation(in: .unknown).rules
    #expect(rules.apply(to: "Frob nicate the quux kit, then slash zap") == "Frobnicate the QuuxKit, then /zap")
    #expect(rules.apply(to: "Ask zor blax about snorp ctl") == "Ask Zorblax about snorp-ctl")
}

@Test func importingTwiceCreatesNoDuplicates() async throws {
    let store = try Lexicon(paths: .temporary())
    let file = try LexiconFile(contentsOf: sample)
    _ = try await store.add(file.entries)
    let (terms, rules) = (await store.terms, await store.rules)

    let again = try await store.add(file.entries)

    #expect(again == ImportCounts(terms: 0, rules: 0, duplicates: 11))
    #expect(await store.terms == terms)
    #expect(await store.rules == rules)
}

@Test func anImportNeverChangesWhatTheLexiconAlreadyHas() async throws {
    let store = try Lexicon(paths: .temporary())
    try await store.add(Term(text: "zorBLAX"))
    try await store.add(Rule(heard: "Quux Kit", written: "QUUXKIT", source: .learned))

    let added = try await store.add(LexiconFile(parsing: "Zorblax\nquux kit -> QuuxKit\nVexmo\n").entries)

    #expect(added == ImportCounts(terms: 1, rules: 0, duplicates: 2))
    #expect(await store.terms.map(\.text) == ["zorBLAX", "Vexmo"])
    #expect(await store.rules == [Rule(heard: "Quux Kit", written: "QUUXKIT", source: .learned)])
}

@Test func anImportSurvivesAReopen() async throws {
    let paths = AppPaths.temporary()
    _ = try await Lexicon(paths: paths).add(try LexiconFile(contentsOf: sample).entries)
    let reopened = try Lexicon(paths: paths)
    #expect(await reopened.terms.count == 6)
    #expect(await reopened.rules.count == 4)
}

@Test func aMissingFileIsAnError() {
    #expect(throws: (any Error).self) {
        try LexiconFile(contentsOf: sample.deletingLastPathComponent().appending(path: "no-such-lexicon.txt"))
    }
}
