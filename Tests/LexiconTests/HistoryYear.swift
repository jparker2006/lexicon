import Foundation
@testable import History
import LexiconDomain
@testable import LexiconUI

// The synthetic year of History that several test files read: about 36,500
// Dictations seeded in one transaction. year() seeds it once per test process,
// so each test that only reads it pays nothing after the first.
//
// The names here are internal, but not `pacific` or `now`: other test files keep
// private declarations of those names, and an internal one of the same name would
// make their uses ambiguous. HistoryReaderTests aliases the clock to its own names.

/// The seeded year's calendar: Los Angeles, so day boundaries and DST never depend on the machine.
let yearCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

/// The fake clock: Sunday 11 October 2026, 15:00 in Los Angeles.
let yearNow = yearCalendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!

/// About three times Jake's rate (the spec's 441 Wispr clips in about two weeks is about 30 a day).
let perDay = 100
let yearDays = 365
let marker = "zanzibar"
/// Every 97th Dictation says the marker word, in a known place.
let markerEvery = 97

/// Deterministic synthetic text: no real Dictation, no randomness between runs.
private struct Synthetic {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D
    private static let words = """
        the auth callback should retry once then fall back to the local model and log the lag so we can see \
        whether the cloud helps make sure history opens fast and search stays under twenty milliseconds please \
        ship it after the tests pass and the reviewer merges keep the clipboard as it was
        """.split(separator: " ").map(String.init)

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func sentence(_ index: Int) -> String {
        let count = 8 + Int(next() % 90)
        var words = (0..<count).map { _ in Self.words[Int(next() % UInt64(Self.words.count))] }
        if index % markerEvery == 0 { words.insert(index % 2 == 0 ? marker : marker.uppercased(), at: words.count / 2) }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }
}

/// One seeded year for every test that only reads it.
@MainActor private var seededYear: Task<(paths: AppPaths, total: Int), any Error>?

/// The shared year's paths and Dictation count. The first caller seeds it.
@MainActor func year() async throws -> (paths: AppPaths, total: Int) {
    if seededYear == nil {
        seededYear = Task {
            let paths = AppPaths.temporary()
            let store = try HistoryStore(paths: paths)
            return (paths, try await seedYear(store))
        }
    }
    return try await seededYear!.value
}

/// `perDay` Dictations on each of the last `yearDays` days, newest at `yearNow`, spread over waking hours.
func seedYear(_ store: HistoryStore, perDay: Int = perDay) async throws -> Int {
    var synthetic = Synthetic()
    var rows: [(id: String, at: Int64, text: String)] = []
    for day in 0..<yearDays {
        let date = yearCalendar.date(byAdding: .day, value: -day, to: yearCalendar.startOfDay(for: yearNow))!
        for slot in 0..<perDay {
            // 07:00 to 15:00, so today's rows are all before the fake clock.
            let ms = date.unixMs + Int64(7 * 3_600_000) + Int64(slot) * (28_800_000 / Int64(perDay))
            rows.append((DictationID().description, ms, synthetic.sentence(rows.count)))
        }
    }
    let cleanup = try CleanupOutcome.rulesOnly(.off).column()
    let model = SpeechModel.local(.parakeetUnified).id
    try await store.read { [rows] db in
        try db.transaction { db in
            for row in rows {
                try db.execute("""
                    INSERT INTO dictation (id, started_at, origin, purpose, status, model_text, cleaned_text, final_text,
                                           cleanup, model, lag_ms, audio_storage)
                    VALUES (?, ?, 'live', 'type', 'inserted', ?, ?, ?, ?, ?, 480, 'onDisk')
                    """, [.text(row.id), .int(row.at), .text(row.text), .text(row.text), .text(row.text),
                          .text(cleanup), .text(model)])
            }
        }
    }
    return rows.count
}
