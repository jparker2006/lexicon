import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

@Test func searchFindsAWholeDictionaryEntryByWrittenOrHeardTextIgnoringCaseAndAccents() {
    let entries: [LexiconEntry] = [
        .rule(Rule(heard: "coffee kit", written: "Café")),
        .term(Term(text: "Zorblax")),
        .rule(Rule(heard: "café kit", written: "Café")),
        .term(Term(text: "Café")),
    ]
    let expected = ["Café (heard as: café kit, coffee kit)"]

    for query in ["cafe", "CAFÉ", "CAFE KIT", "Café Kit", "COFFEE KIT"] {
        #expect(searchTitles(in: entries, matching: query) == expected, "query: \(query)")
    }
}

@Test func blankSearchShowsEveryDictionaryEntryAndAnUnmatchedQueryShowsNone() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Zorblax")),
        .term(Term(text: "Café")),
        .rule(Rule(heard: "café kit", written: "Café")),
    ]
    let allTitles = ["Café (heard as: café kit)", "Zorblax"]

    for query in ["", "   "] {
        let titles = searchTitles(in: entries, matching: query)
        #expect(titles.count == allTitles.count)
        #expect(Set(titles) == Set(allTitles))
    }
    #expect(searchTitles(in: entries, matching: "quux").isEmpty)
}

@Test func searchKeepsCaseAndAccentVariantsAsSeparateDictionaryEntries() {
    let entries: [LexiconEntry] = [
        .term(Term(text: "Codex")),
        .rule(Rule(heard: "code ex", written: "Codex")),
        .term(Term(text: "CODEX")),
        .rule(Rule(heard: "code ex caps", written: "CODEX")),
        .term(Term(text: "Cafe")),
        .rule(Rule(heard: "cafe word", written: "Cafe")),
        .term(Term(text: "Café")),
        .rule(Rule(heard: "coffee shop", written: "Café")),
    ]

    let caseVariants = searchTitles(in: entries, matching: "code")
    #expect(caseVariants.count == 2)
    #expect(Set(caseVariants) == Set([
        "Codex (heard as: code ex)",
        "CODEX (heard as: code ex caps)",
    ]))

    let accentVariants = searchTitles(in: entries, matching: "cafe")
    #expect(accentVariants.count == 2)
    #expect(Set(accentVariants) == Set([
        "Cafe (heard as: cafe word)",
        "Café (heard as: coffee shop)",
    ]))
}

private func searchTitles(in entries: [LexiconEntry], matching query: String) -> [String] {
    LexiconText.sorted(entries)
        .filter { LexiconText.matches($0, query) }
        .map { LexiconText.title(for: $0) }
}
