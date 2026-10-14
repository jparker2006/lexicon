import Foundation
import Testing
@testable import LexiconUI
import LexiconDomain
import WordStore

private let sampleLexiconURL = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "scorer/fixtures/sample-lexicon.txt")

@Test func importingThePublicSampleTwiceKeepsRecordsAndGroupedEntriesUnchanged() async throws {
    let lexicon = try Lexicon(paths: .temporary())

    let firstCounts = try await lexicon.add(contentsOf: sampleLexiconURL)
    let firstRecords = await lexicon.entries
    let firstTitles = LexiconText.sorted(firstRecords).map { LexiconText.title(for: $0) }

    #expect(firstCounts == ImportCounts(terms: 6, rules: 4, duplicates: 1, unreadable: 1))
    #expect(firstRecords.count == 10)
    #expect(firstTitles.count == 9)
    #expect(Set(firstTitles) == Set([
        "Zorblax",
        "QuuxKit (heard as: quux kit)",
        "flimDB",
        "snorp-ctl",
        "Vexmo",
        "Trellium.md",
        "Frobnicate (heard as: frob nicate)",
        "/zap (heard as: slash zap)",
        "kubenector (heard as: cube nector)",
    ]))

    let secondCounts = try await lexicon.add(contentsOf: sampleLexiconURL)
    let secondRecords = await lexicon.entries
    let secondTitles = LexiconText.sorted(secondRecords).map { LexiconText.title(for: $0) }

    #expect(secondCounts == ImportCounts(duplicates: 11, unreadable: 1))
    #expect(secondRecords == firstRecords)
    #expect(secondTitles == firstTitles)
}
