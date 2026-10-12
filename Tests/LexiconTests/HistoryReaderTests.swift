import Foundation
import Testing
@testable import History
import LexiconDomain
@testable import LexiconUI

// The History window's reader over a throwaway data folder. Small cases go in
// through History's write API; the year-sized cases are seeded with synthetic
// text in one transaction. A fixed clock and time zone, so day headers and
// DST never depend on when or where the tests run.

private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

/// The fake clock: Sunday 11 October 2026, 15:00 in Los Angeles.
private let now = pacific.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    pacific.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
}

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let parakeet = SpeechModel.local(.parakeetUnified)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic", storage: .onDisk, gaps: [])

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// A live Dictation recorded through to inserted, as the Conductor would.
@discardableResult
private func dictate(_ store: HistoryStore, _ text: String, at start: Date) -> DictationID {
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: text, cleaned: text), cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    store.record(.delivered(id, InsertionReceipt(appBundleID: app.bundleID, fieldFingerprint: nil, caretAfter: nil,
                                                 contextBefore: "", contextAfter: "", insertedAt: start),
                            lag: .milliseconds(420)))
    return id
}

/// Every matching day, read `batch` rows at a time as the window does when
/// Jake scrolls to the end. A batch of 1 cuts every day short, so each day's
/// count comes from the reader finishing the day it was cut in.
@MainActor
private func days(_ reader: HistoryReader, _ query: String? = nil, batch: Int = 1) -> [DaySection] {
    var all: [DaySection] = []
    while true {
        let more = reader.sections(matching: query, after: all.last, rows: batch)
        if more.isEmpty { return all }
        all += more
    }
}

/// Every row of every section, page by page, as the window would fetch them.
@MainActor
private func allRows(_ reader: HistoryReader, _ sections: [DaySection], page: Int = 50) -> [[HistoryRow]] {
    sections.map { section in
        stride(from: 0, to: section.count, by: page).flatMap { reader.rows(in: section, offsets: $0..<min($0 + page, section.count)) }
    }
}

// MARK: - A year of synthetic History

/// About three times Jake's rate (the spec's 441 Wispr clips in about two weeks is about 30 a day).
private let perDay = 100
private let jakesRate = 30
private let yearDays = 365
private let marker = "zanzibar"
/// Every 97th Dictation says the marker word, in a known place.
private let markerEvery = 97

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

@MainActor private func year() async throws -> (paths: AppPaths, total: Int) {
    if seededYear == nil {
        seededYear = Task {
            let (store, paths) = try makeStore()
            return (paths, try await seedYear(store))
        }
    }
    return try await seededYear!.value
}

/// `perDay` Dictations on each of the last `yearDays` days, newest at `now`, spread over waking hours.
private func seedYear(_ store: HistoryStore, perDay: Int = perDay) async throws -> Int {
    var synthetic = Synthetic()
    var rows: [(id: String, at: Int64, text: String)] = []
    for day in 0..<yearDays {
        let date = pacific.date(byAdding: .day, value: -day, to: pacific.startOfDay(for: now))!
        for slot in 0..<perDay {
            // 07:00 to 15:00, so today's rows are all before the fake clock.
            let ms = date.unixMs + Int64(7 * 3_600_000) + Int64(slot) * (28_800_000 / Int64(perDay))
            rows.append((DictationID().description, ms, synthetic.sentence(rows.count)))
        }
    }
    let cleanup = try CleanupOutcome.rulesOnly(.off).column()
    try await store.read { [rows] db in
        try db.transaction { db in
            for row in rows {
                try db.execute("""
                    INSERT INTO dictation (id, started_at, origin, purpose, status, model_text, cleaned_text, final_text,
                                           cleanup, model, lag_ms, audio_storage)
                    VALUES (?, ?, 'live', 'type', 'inserted', ?, ?, ?, ?, ?, 480, 'onDisk')
                    """, [.text(row.id), .int(row.at), .text(row.text), .text(row.text), .text(row.text),
                          .text(cleanup), .text(parakeet.id)])
            }
        }
    }
    return rows.count
}

// MARK: - Rows

@MainActor @Test func aDictationShowsUnderItsDayWithEverythingTheRowDraws() async throws {
    let (store, paths) = try makeStore()
    let id = dictate(store, "Wire the auth callback into Supabase.", at: at(10, 11, 9, 41))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader)
    #expect(sections.map(\.day) == [DateComponents(year: 2026, month: 10, day: 11)])
    #expect(sections.map(\.count) == [1])

    let row = try #require(reader.rows(in: sections[0], offsets: 0..<1).first)
    #expect(row.id == id)
    #expect(row.startedAt == at(10, 11, 9, 41))
    #expect(row.finalText == "Wire the auth callback into Supabase.")
    #expect(row.status == .inserted)
    #expect(row.model == parakeet)
    #expect(row.lag == .milliseconds(420))
    #expect(row.cleanup == .rulesOnly(.off))
    #expect(row.hasAudio)
    #expect(!row.pinned)
}

@MainActor @Test func aDictationThatIsNotInsertedShowsItsStatusAndNoTextYet() async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: at(10, 11, 9), app: app))
    store.record(.audioEnded(id, audio))
    store.record(.waiting(id, reason: "offline"))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let row = try #require(reader.rows(in: days(reader)[0], offsets: 0..<1).first)
    #expect(row.status == .waiting)
    #expect(row.finalText == nil)
    #expect(row.model == nil)
    #expect(row.lag == nil)
}

@MainActor @Test func fullTextComesBackWhole() async throws {
    let (store, paths) = try makeStore()
    let long = String(repeating: "Every word of a long hands-free Dictation stays in History. ", count: 200)
    dictate(store, long, at: at(10, 11, 9))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    #expect(reader.rows(in: days(reader)[0], offsets: 0..<1).first?.finalText == long)
}

@MainActor @Test func daysAreNewestFirstAndEndAtLocalMidnightThroughADSTChange() async throws {
    let (store, paths) = try makeStore()
    // 1 November 2026 is the day clocks fall back in Los Angeles: a 25-hour day.
    dictate(store, "Late on Halloween.", at: at(10, 31, 23, 59))
    dictate(store, "Just after midnight.", at: at(11, 1, 0, 1))
    dictate(store, "The extra hour, late at night.", at: at(11, 1, 23, 30))
    dictate(store, "Next morning.", at: at(11, 2, 8))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader)
    #expect(sections.map(\.day) == [DateComponents(year: 2026, month: 11, day: 2), DateComponents(year: 2026, month: 11, day: 1),
                                    DateComponents(year: 2026, month: 10, day: 31)])
    #expect(allRows(reader, sections).map { $0.compactMap(\.finalText) } == [
        ["Next morning."], ["The extra hour, late at night.", "Just after midnight."], ["Late on Halloween."],
    ])
}

@MainActor @Test func aDeletedDictationIsGone() async throws {
    let (store, paths) = try makeStore()
    let kept = dictate(store, "Keep this one.", at: at(10, 11, 9))
    let gone = dictate(store, "Delete this one.", at: at(10, 11, 10))
    try Data([0]).write(to: store.audioURL(for: gone))
    store.record(.deleted(gone))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader)
    #expect(sections.map(\.count) == [1])
    #expect(reader.rows(in: sections[0], offsets: 0..<5).map(\.id) == [kept])
}

@MainActor @Test func aRowWithAStatusFromANewerBuildIsNeitherShownNorCounted() async throws {
    let (store, paths) = try makeStore()
    let kept = dictate(store, "Known status.", at: at(10, 11, 9))
    try await store.read { db in
        try db.execute("""
            INSERT INTO dictation (id, started_at, origin, purpose, status, final_text, audio_storage)
            VALUES (?, ?, 'live', 'type', 'someFutureStatus', 'From a newer build.', 'onDisk')
            """, [.text(DictationID().description), .int(at(10, 11, 10).unixMs)])
    }

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader)
    #expect(sections.map(\.count) == [1])
    #expect(reader.rows(in: sections[0], offsets: 0..<5).map(\.id) == [kept])
}

@MainActor @Test func beforeTheFirstDictationHistoryIsEmptyUntilOneArrives() async throws {
    let paths = AppPaths.temporary()
    let reader = HistoryReader(paths: paths, calendar: pacific)
    #expect(days(reader).isEmpty)
    #expect(days(reader, "anything").isEmpty)
    #expect(!FileManager.default.fileExists(atPath: paths.root.appending(path: "history.sqlite").path(percentEncoded: false)))
    let empty = reader.version

    // A window opened before the first Dictation shows it once it lands.
    let store = try HistoryStore(paths: paths)
    dictate(store, "The very first Dictation.", at: at(10, 11, 9))
    await store.flush()
    #expect(reader.version != empty)
    #expect(days(reader).map(\.count) == [1])
}

@MainActor @Test func historyReadsWithNoWriterOpen() async throws {
    // The window can open while nothing holds history.sqlite open. A clean close
    // leaves the main file alone, without the WAL's -shm and -wal files, and a
    // read-only connection cannot make them itself.
    let (store, written) = try makeStore()
    dictate(store, "Written, then the writer closed.", at: at(10, 11, 9))
    await store.flush()
    try await store.read { db in try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    let paths = AppPaths.temporary()
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: written.root.appending(path: "history.sqlite"), to: paths.root.appending(path: "history.sqlite"))

    let reader = HistoryReader(paths: paths, calendar: pacific)
    #expect(days(reader).map(\.count) == [1])
}

@MainActor @Test func versionMovesWhenTheWriterCommitsSoTheWindowKnowsToReload() async throws {
    let (store, paths) = try makeStore()
    dictate(store, "First.", at: at(10, 11, 9))
    await store.flush()
    let reader = HistoryReader(paths: paths, calendar: pacific)
    let before = reader.version
    #expect(reader.version == before)

    dictate(store, "Second.", at: at(10, 11, 10))
    await store.flush()
    #expect(reader.version != before)
    #expect(days(reader).map(\.count) == [2])
}

// MARK: - Detail and audio

@MainActor @Test func aDetailShowsEveryVersionAndEveryEnginesRun() async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    let model = "wire the auth callback into super base"
    let cleaned = "Wire the auth callback into Supabase."
    let cloud = AttemptRecord(model: .cloud(.museVoice), result: .timedOut, text: nil, latency: .milliseconds(1_500), error: "deadline")
    let won = AttemptRecord(model: parakeet, result: .won, text: model, latency: .milliseconds(90), error: nil)
    store.record(.began(id, origin: .live, purpose: .type, at: at(10, 11, 9), app: app))
    store.record(.attempted(id, cloud))
    store.record(.attempted(id, won))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, TextVersions(model: model, cleaned: cleaned), cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    store.record(.delivered(id, InsertionReceipt(appBundleID: app.bundleID, fieldFingerprint: nil, caretAfter: nil,
                                                 contextBefore: "", contextAfter: "", insertedAt: at(10, 11, 9)),
                            lag: .milliseconds(420)))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    let detail = try #require(reader.detail(id))
    #expect(detail.row.id == id)
    #expect(detail.row.finalText == cleaned)
    #expect(detail.versions == TextVersions(model: model, cleaned: cleaned))
    #expect(detail.attempts == [cloud, won])
}

@MainActor @Test func aDeletedDictationHasNoDetail() async throws {
    let (store, paths) = try makeStore()
    let gone = dictate(store, "Delete this one.", at: at(10, 11, 10))
    store.record(.deleted(gone))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    #expect(reader.detail(gone) == nil)
    #expect(reader.detail(DictationID()) == nil)
}

@MainActor @Test func thePlayButtonGetsTheAudioUntilRetentionTakesIt() async throws {
    let (store, paths) = try makeStore()
    let dictated = at(10, 11, 9)
    let id = dictate(store, "Play this one.", at: dictated)
    try Data([0, 1]).write(to: store.audioURL(for: id))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    #expect(reader.audioURL(id) == store.audioURL(for: id))
    #expect(reader.audioURL(DictationID()) == nil)

    await store.sweepAudio(now: dictated.addingTimeInterval(15 * 86_400))
    #expect(reader.audioURL(id) == nil)
}

// MARK: - Search

@MainActor @Test func searchIsAPlainCaseInsensitiveMatchOnFinalText() async throws {
    let (store, paths) = try makeStore()
    dictate(store, "Move the Supabase keys.", at: at(10, 10, 9))
    dictate(store, "We are 100% done.", at: at(10, 11, 9))
    dictate(store, "Rename it to snake_case.", at: at(10, 11, 10))
    dictate(store, "Escape the back\\slash.", at: at(10, 11, 11))
    await store.flush()

    let reader = HistoryReader(paths: paths, calendar: pacific)
    func found(_ query: String?) -> [String] {
        allRows(reader, days(reader, query)).flatMap { $0.compactMap(\.finalText) }
    }
    #expect(found("supabase") == ["Move the Supabase keys."])
    #expect(found("SUPA") == ["Move the Supabase keys."])
    // LIKE's wildcards and its escape character match only themselves.
    #expect(found("%") == ["We are 100% done."])
    #expect(found("_") == ["Rename it to snake_case."])
    #expect(found("\\") == ["Escape the back\\slash."])
    #expect(found("nothing like this") == [])
    #expect(found("  ").count == 4)
    #expect(found(nil).count == 4)
}

// MARK: - A year of History

@MainActor @Test func aYearOfHistoryOpensOnTodayAndPagesThroughEveryDay() async throws {
    let (paths, total) = try await year()
    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader, batch: 300)
    #expect(sections.count == yearDays)
    #expect(sections.first?.day == DateComponents(year: 2026, month: 10, day: 11))
    #expect(sections.allSatisfy { $0.count == perDay })
    #expect(sections.reduce(0) { $0 + $1.count } == total)

    // First rows: one page of today's newest.
    let first = reader.rows(in: sections[0], offsets: 0..<20)
    #expect(first.count == 20)
    #expect(first.map(\.startedAt) == first.map(\.startedAt).sorted(by: >))
    #expect(first.allSatisfy { pacific.isDate($0.startedAt, inSameDayAs: now) })

    // Paging a day returns each of its rows once, in order, and only that day's.
    let pages = allRows(reader, Array(sections.prefix(3)), page: 30)
    for (section, rows) in zip(sections, pages) {
        #expect(rows.count == section.count)
        #expect(Set(rows.map(\.id)).count == section.count)
        #expect(rows.map(\.startedAt) == rows.map(\.startedAt).sorted(by: >))
        #expect(rows.allSatisfy { pacific.dateComponents([.year, .month, .day], from: $0.startedAt) == section.day })
    }
}

@MainActor @Test func openingAYearReadsOnlyTheNewestDaysThatFillTheBatch() async throws {
    let (paths, _) = try await year()
    let reader = HistoryReader(paths: paths, calendar: pacific)
    // 250 rows asked for: two whole days fall short, so the third day comes back whole too.
    let first = reader.sections(matching: nil, rows: 250)
    #expect(first.map(\.day) == [DateComponents(year: 2026, month: 10, day: 11), DateComponents(year: 2026, month: 10, day: 10),
                                 DateComponents(year: 2026, month: 10, day: 9)])
    #expect(first.map(\.count) == [perDay, perDay, perDay])
    let next = reader.sections(matching: nil, after: first.last, rows: 250)
    #expect(next.first?.day == DateComponents(year: 2026, month: 10, day: 8))
}

@MainActor @Test func searchOverAYearFindsEveryMatchAndNothingElse() async throws {
    let (paths, total) = try await year()
    let reader = HistoryReader(paths: paths, calendar: pacific)
    let sections = days(reader, marker, batch: 300)
    let rows = allRows(reader, sections).flatMap { $0 }
    #expect(rows.count == (total + markerEvery - 1) / markerEvery)
    #expect(sections.reduce(0) { $0 + $1.count } == rows.count)
    #expect(rows.allSatisfy { $0.finalText?.lowercased().contains(marker) == true })
}

// MARK: - Speed (opt in: LEXICON_TIMING=1)

// The window's two latency targets, measured on a year of synthetic History.
// Wall-clock numbers depend on the machine, so these are timing runs only
// (Tests/TestSupport/TimingRun.swift); run them alone, on a quiet Mac:
//
//     LEXICON_TIMING=1 scripts/lib/heavy.sh --quiet scripts/test.sh --filter speed

private func percentile(_ samples: [Duration], _ p: Double) -> Duration {
    let sorted = samples.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
}

@MainActor @Test(.enabled(if: timingRun)) func speedFirstRowsWithinBudget() async throws {
    let paths = try await year().paths
    let clock = ContinuousClock()
    var samples: [Duration] = []
    for _ in 0..<50 {
        samples.append(clock.measure {
            // What a window open costs the reader: a new connection, the day sections, the first screenful.
            let reader = HistoryReader(paths: paths, calendar: pacific)
            let sections = reader.sections(matching: nil, rows: 300)
            _ = reader.rows(in: sections[0], offsets: 0..<30)
        })
    }
    print("History reader, first rows over \(perDay * yearDays) Dictations: p50 \(percentile(samples, 0.5)), p95 \(percentile(samples, 0.95))")
    #expect(percentile(samples, 0.95) <= .milliseconds(100))
}

/// Search over `paths` with a few queries, as Jake types them: day sections plus the first screenful.
@MainActor
private func searchTimes(_ paths: AppPaths) -> [Duration] {
    let reader = HistoryReader(paths: paths, calendar: pacific)
    let clock = ContinuousClock()
    return ["zanzibar", "callback", "milliseconds please", "no such words anywhere"].flatMap { query in
        (0..<10).map { _ in
            clock.measure {
                let sections = reader.sections(matching: query, rows: 300)
                if let first = sections.first { _ = reader.rows(in: first, offsets: 0..<30) }
            }
        }
    }
}

/// The target is about 20 ms at Jake's own rate; the heavy year is reported, not held to it.
@MainActor @Test(.enabled(if: timingRun)) func speedSearchWithinTarget() async throws {
    let (store, paths) = try makeStore()
    let total = try await seedYear(store, perDay: jakesRate)
    let samples = searchTimes(paths)
    let heavy = searchTimes(try await year().paths)
    print("History search over \(total) Dictations: p50 \(percentile(samples, 0.5)), p95 \(percentile(samples, 0.95))")
    print("History search over \(perDay * yearDays) Dictations: p50 \(percentile(heavy, 0.5)), p95 \(percentile(heavy, 0.95))")
    #expect(percentile(samples, 0.5) <= .milliseconds(25))
}

/// The whole window, not just its reader: built, ordered in (transparent, never
/// key) and drawn, as the app's "first rows drawn" line times it, on every open
/// after launch's warm-up. Run it beside main to catch an open that got slower
/// before a release build goes to Live checks.
@MainActor @Test(.enabled(if: timingRun)) func speedWindowOpenWithinBudget() async throws {
    let paths = try await year().paths
    let presenter = HistoryWindowPresenter(paths: paths, system: nil)
    autoreleasepool { _ = presenter.warmUp() }
    /// Orders the window in and draws it, as the presenter's show() does.
    func show(_ controller: HistoryWindowController) {
        controller.window?.alphaValue = 0
        controller.showWindow(nil)
        controller.window?.displayIfNeeded()
    }
    // Untimed: the app has drawn its status item and menu before History ever opens,
    // and a test process has drawn nothing, so its very first window pays for that.
    // Its pasteboard, never Jake's, serves every timed open, so none is made inside the timing.
    var first: HistoryWindowController? = HistoryWindowController(
        reader: HistoryReader(paths: paths), system: nil, pasteboard: .withUniqueName()) {}
    let pasteboard = first!.pasteboard
    autoreleasepool {
        show(first!)
        first?.close()
        first = nil
    }
    let clock = ContinuousClock()
    let samples = (0..<20).map { _ in
        autoreleasepool {
            let start = clock.now
            let controller = HistoryWindowController(reader: HistoryReader(paths: paths), system: nil, pasteboard: pasteboard) {}
            show(controller)
            let took = clock.now - start
            controller.close()
            return took
        }
    }
    print("History window, open to first rows over \(perDay * yearDays) Dictations: first \(samples[0]), "
        + "p50 \(percentile(samples, 0.5)), p95 \(percentile(samples, 0.95))")
    #expect(percentile(samples, 0.95) <= .milliseconds(100))
}
