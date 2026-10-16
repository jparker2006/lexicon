import Foundation
import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

private func addTypedEntry(_ text: String, to store: Lexicon) async throws {
    let entry = try #require(LexiconText.entry(typed: text), "The Add line should parse: \(text)")
    switch entry {
    case .term(let term): try await store.add(term)
    case .rule(let rule): try await store.add(rule)
    }
}

private func displayedTitles(in store: Lexicon) async -> [String] {
    LexiconText.sorted(await store.entries).map { LexiconText.title(for: $0) }
}

@Test func addingBareAndHeardAsLinesShowsOneExactSpellingEntry() async throws {
    let store = try Lexicon(paths: .temporary())

    try await addTypedEntry("Supabase", to: store)
    try await addTypedEntry("  SUPABASE  ", to: store)
    try await addTypedEntry("super base -> SUPABASE", to: store)
    try await addTypedEntry("super bass -> SUPABASE", to: store)

    let entries = await store.entries
    #expect(await store.terms == [Term(text: "SUPABASE")])
    #expect(entries.count == 3)
    #expect(await displayedTitles(in: store) == [
        "SUPABASE (heard as: super base, super bass)",
    ])
}

@Test func readdingEquivalentHeardSideUpdatesItsRuleAndMovesItToTheExactNewSpelling() async throws {
    let store = try Lexicon(paths: .temporary())

    try await addTypedEntry("Supabase", to: store)
    try await addTypedEntry("super base -> Supabase", to: store)
    try await addTypedEntry("super bass -> Supabase", to: store)
    try await store.add(Rule(heard: "  SUPER   BASE  ", written: "SupaBase", source: .learned))

    let entries = await store.entries
    let rules = await store.rules
    #expect(entries.count == 3)
    #expect(rules.count == 2)
    #expect(Set(rules) == Set([
        Rule(heard: "SUPER BASE", written: "SupaBase", source: .learned),
        Rule(heard: "super bass", written: "Supabase", source: .added),
    ]))
    let titles = await displayedTitles(in: store)
    #expect(titles.count == 2)
    #expect(Set(titles) == Set([
        "SupaBase (heard as: ✨ SUPER BASE)",
        "Supabase (heard as: super bass)",
    ]))
}

@Test func groupingKeepsCanonicallyEquivalentWrittenSpellingsDistinct() async throws {
    let store = try Lexicon(paths: .temporary())
    let composed = "Café"
    let decomposed = "Cafe\u{301}"

    try await store.add(Rule(heard: "cafe cue", written: composed))
    try await store.add(Rule(heard: "coffee key", written: decomposed))

    let titles = await displayedTitles(in: store)
    let actualBytes = titles.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    let expectedBytes = [
        "Café (heard as: cafe cue)",
        "Cafe\u{301} (heard as: coffee key)",
    ].map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    #expect(titles.count == 2)
    #expect(actualBytes == expectedBytes)
}
