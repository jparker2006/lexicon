import Foundation
import Testing
@testable import History
import LexiconDomain

// Old rows: the `cleanup` column in the shape History stores it, pinned as literal
// JSON for every outcome this build can write. The reader has to decode those exact bytes. A test that round-trips
// through the encoder would pass after an encoding change that old rows cannot read,
// so the literals are copied from the encoder once and never regenerated.
//
// A row whose engine this build no longer has is still History. It shows its text,
// with no cleanup outcome to draw, and it is neither hidden nor dropped.

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

@MainActor
private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// Inserts rows the way an older build left them: only the columns the list reads,
/// `cleanup` exactly as given, one minute apart on one day.
private func insertOldRows(_ store: HistoryStore, _ rows: [(id: String, text: String, cleanup: String)]) async throws {
    let start = pacific.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9))!.unixMs
    try await store.read { [rows] db in
        for (index, row) in rows.enumerated() {
            try db.execute("""
                INSERT INTO dictation (id, started_at, origin, purpose, status, final_text, cleanup, audio_storage)
                VALUES (?, ?, 'live', 'type', 'inserted', ?, ?, 'onDisk')
                """, [.text(row.id), .int(start + Int64(index) * 60_000), .text(row.text), .text(row.cleanup)])
        }
    }
}

/// Every row the History window would list, newest first.
@MainActor
private func listed(_ reader: HistoryReader) -> [HistoryRow] {
    reader.sections(matching: nil, rows: 100).flatMap { reader.rows(in: $0, offsets: 0..<$0.count) }
}

@MainActor
struct HistoryOldRowsTests {
    @Test func rowsWrittenByEveryCurrentCleanupOutcomeStillDecodeToThatOutcome() async throws {
        let (store, paths) = try makeStore()
        let cases: [(id: DictationID, text: String, cleanup: String, outcome: CleanupOutcome)] = [
            (DictationID(), "Cloud cleaned.", #"{"aiAccepted":{"_0":{"cloud":{"_0":"openrouter.fast"}}}}"#,
             .aiAccepted(.cloud(.openRouterFast))),
            (DictationID(), "Cleanup off.", #"{"rulesOnly":{"_0":{"off":{}}}}"#,
             .rulesOnly(.off)),
            (DictationID(), "Dropped a word.", #"{"rulesOnly":{"_0":{"rejected":{"_0":"droppedContentWord"}}}}"#,
             .rulesOnly(.rejected(.droppedContentWord))),
            (DictationID(), "Added a word.", #"{"rulesOnly":{"_0":{"rejected":{"_0":"addedWord"}}}}"#,
             .rulesOnly(.rejected(.addedWord))),
            (DictationID(), "Changed a number.", #"{"rulesOnly":{"_0":{"rejected":{"_0":"numberMismatch"}}}}"#,
             .rulesOnly(.rejected(.numberMismatch))),
            (DictationID(), "Ran too long.", #"{"rulesOnly":{"_0":{"rejected":{"_0":"tooLong"}}}}"#,
             .rulesOnly(.rejected(.tooLong))),
            (DictationID(), "Wrote unspoken code.", #"{"rulesOnly":{"_0":{"rejected":{"_0":"unspokenCode"}}}}"#,
             .rulesOnly(.rejected(.unspokenCode))),
            (DictationID(), "Cleanup past its deadline.", #"{"rulesOnly":{"_0":{"deadline":{}}}}"#,
             .rulesOnly(.deadline)),
            (DictationID(), "No cleanup model ran.", #"{"rulesOnly":{"_0":{"unavailable":{}}}}"#,
             .rulesOnly(.unavailable)),
        ]
        try await insertOldRows(store, cases.map { (id: $0.id.description, text: $0.text, cleanup: $0.cleanup) })

        let reader = HistoryReader(paths: paths, calendar: pacific)
        let byID = Dictionary(uniqueKeysWithValues: listed(reader).map { ($0.id, $0) })
        for testCase in cases {
            let row = try #require(byID[testCase.id])
            #expect(row.finalText == testCase.text)
            #expect(row.cleanup == testCase.outcome)
        }
    }

    @Test func aRowWhoseEngineThisBuildNoLongerHasStillShowsItsText() async throws {
        let (store, paths) = try makeStore()
        let id = DictationID()
        // An engine this build doesn't know, in the shape a dropped engine case leaves.
        // A row this build can't decode must still show, not vanish.
        try await insertOldRows(store, [(id: id.description, text: "Cleaned by a retired engine.",
                                         cleanup: #"{"aiAccepted":{"_0":{"retiredEngine":{}}}}"#)])

        let reader = HistoryReader(paths: paths, calendar: pacific)
        let row = try #require(listed(reader).first { $0.id == id })
        #expect(row.finalText == "Cleaned by a retired engine.")
        #expect(row.cleanup == nil)
    }
}
