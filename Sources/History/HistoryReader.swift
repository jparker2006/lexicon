public import Foundation
public import LexiconDomain
import SQLiteKit
import os

/// The History window's read side. Its own read-only connection (WAL allows a
/// reader beside the writer), confined to the main thread, opened with the
/// window (or with the first Dictation, if the window came first) and closed
/// when it closes, so a closed window costs nothing.
///
/// Access pattern (NSTableView asks only for rows on screen): the table's flat
/// index is [day header, rows..., day header, rows...]. `sections` reads the
/// newest stretch of the `started_at` index (plus the table for the search
/// match) and buckets it into local days in Swift, so the calendar decides
/// where a day ends, DST included. Rows are then fetched a page at a time
/// within one day (its `started_at` range plus a small OFFSET). Opening the
/// window costs a few hundred index entries plus one page, whatever the
/// History size: no Dictation's text is read until its row is on screen.
@MainActor
public final class HistoryReader {
    private let file: URL
    private let paths: AppPaths
    private let calendar: Calendar
    /// nil until `history.sqlite` exists: before the first Dictation, History is empty.
    private var opened: Database?
    private let log = Logger(subsystem: "Lexicon", category: "History")

    /// `calendar` decides the day buckets; tests pass a fixed time zone.
    public init(paths: AppPaths, calendar: Calendar = .current) {
        file = paths.root.appending(path: "history.sqlite")
        self.paths = paths
        self.calendar = calendar
    }

    private var db: Database? {
        if opened == nil, FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            do {
                opened = try Database(at: file, mode: .readOnly, migrations: [])
            } catch {
                log.error("History window cannot read History: \(String(describing: error), privacy: .private)")
            }
        }
        return opened
    }

    /// Changes whenever the writer commits, so the window reloads only when there
    /// is something new. 0 means no History yet; it moves when History appears.
    public var version: Int { db.map { $0.dataVersion &+ 1 } ?? 0 }

    /// Whole days, newest first: the days after `last` (nil: from the newest),
    /// until they hold at least `rows` Dictations or History runs out. The window
    /// asks for a screenful at open and for more as Jake scrolls, so opening
    /// reads the same few hundred timestamps whatever the History size.
    ///
    /// `matching` is a plain-text search over final text, case-insensitive for
    /// ASCII as SQLite's LIKE is (FTS5 only if measured slow: #4). Blank means everything.
    public func sections(matching query: String?, after last: DaySection? = nil, rows: Int) -> [DaySection] {
        guard let db, rows > 0 else { return [] }
        let filter = Filter(query)
        let before = last?.startMs ?? .max
        let times = (try? db.query("""
            SELECT started_at FROM dictation WHERE started_at < ? AND \(filter.sql) ORDER BY started_at DESC LIMIT ?
            """, [.int(before)] + filter.bindings + [.int(Int64(rows))])) ?? []
        var sections: [DaySection] = []
        var day = Int64.max..<Int64.max
        for row in times {
            let ms = row.int(0) ?? 0
            if !day.contains(ms) {
                let start = calendar.startOfDay(for: Date(unixMs: ms))
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                day = start.unixMs..<end.unixMs
                sections.append(DaySection(day: calendar.dateComponents([.year, .month, .day], from: start), count: 0,
                                           startMs: day.lowerBound, newestMs: ms, oldestMs: ms, query: filter.query))
            }
            sections[sections.count - 1].count += 1
            sections[sections.count - 1].oldestMs = ms
        }
        // The limit may have cut the last day short: count all of it (its newest rows all came back).
        if times.count == rows, let open = sections.last,
           let whole = try? db.query("""
               SELECT count(*), min(started_at) FROM dictation WHERE started_at BETWEEN ? AND ? AND \(filter.sql)
               """, [.int(open.startMs), .int(open.newestMs)] + filter.bindings).first,
           let count = whole.int(0), let oldest = whole.int(1) {
            sections[sections.count - 1].count = Int(count)
            sections[sections.count - 1].oldestMs = oldest
        }
        return sections
    }

    /// Newest first within the day.
    public func rows(in section: DaySection, offsets: Range<Int>) -> [HistoryRow] {
        guard let db, !offsets.isEmpty else { return [] }
        let filter = Filter(section.query)
        let rows = (try? db.query("""
            SELECT \(HistoryRow.columns) FROM dictation WHERE started_at BETWEEN ? AND ? AND \(filter.sql)
            ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?
            """, [.int(section.oldestMs), .int(section.newestMs)] + filter.bindings
                + [.int(Int64(offsets.count)), .int(Int64(offsets.lowerBound))])) ?? []
        return rows.compactMap(HistoryRow.init(row:))
    }

    /// "Show versions": model, cleaned, final, what each Retry replaced, plus every engine's run.
    public func detail(_ id: DictationID) -> HistoryDetail? {
        guard let db else { return nil }
        // One snapshot for the row and its child rows: a Retry committing between the reads
        // would show the replaced text as current and again as an earlier version.
        try? db.execute("BEGIN")
        defer { try? db.execute("COMMIT") }
        // The list's rule: a row mid-delete, or a status this build cannot draw, is not shown.
        let found = try? db.query("""
            SELECT \(HistoryRow.columns), model_text, cleaned_text FROM dictation WHERE id = ? AND \(Filter(nil).sql)
            """, [.text(id.description)])
        guard let row = found?.first, let shown = HistoryRow(row: row) else { return nil }
        var versions: TextVersions?
        if let model = row.text(9), let cleaned = row.text(10) { versions = TextVersions(model: model, cleaned: cleaned) }
        let runs = (try? db.query("""
            SELECT model, result, text, latency_ms, error FROM attempt WHERE dictation_id = ? ORDER BY id
            """, [.text(id.description)])) ?? []
        let attempts = runs.compactMap { run -> AttemptRecord? in
            guard let model = run.text(0).flatMap(SpeechModel.init(id:)),
                  let result = run.text(1).flatMap(AttemptRecord.Result.init(rawValue:)) else { return nil }
            return AttemptRecord(model: model, result: result, text: run.text(2),
                                 latency: run.int(3).map { .milliseconds($0) }, error: run.text(4))
        }
        let replaced = (try? db.query("""
            SELECT cleaned_text, final_text, model, replaced_at FROM earlier_version
            WHERE dictation_id = ? ORDER BY replaced_at DESC, rowid DESC
            """, [.text(id.description)])) ?? []
        let earlier = replaced.compactMap { version -> EarlierVersion? in
            guard let cleaned = version.text(0), let final = version.text(1) else { return nil }
            return EarlierVersion(cleaned: cleaned, final: final, model: version.text(2).flatMap(SpeechModel.init(id:)),
                                  replacedAt: Date(unixMs: version.int(3) ?? 0))
        }
        return HistoryDetail(row: shown, versions: versions, attempts: attempts, earlier: earlier)
    }

    /// For the play button (AVAudioPlayer). nil once the audio aged out or was deleted.
    public func audioURL(_ id: DictationID) -> URL? {
        guard let db else { return nil }
        let storage = try? db.query("SELECT audio_storage FROM dictation WHERE id = ?", [.text(id.description)]).first?.text(0)
        guard storage == AudioStorage.onDisk.rawValue else { return nil }
        let url = HistoryStore.audioURL(for: id, in: paths)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

/// The WHERE clause both reads share, so a day's count and its pages always agree.
private struct Filter {
    let query: String?

    init(_ query: String?) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.query = trimmed.isEmpty ? nil : trimmed
    }

    /// A row mid-delete (marked, file not yet gone) has already lost its text, and
    /// a status a newer build wrote cannot be drawn: neither is shown, or counted.
    var sql: String {
        let known = DictationStatus.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        return "audio_storage != '\(AudioStorage.deleted.rawValue)' AND status IN (\(known))"
            + (query == nil ? "" : #" AND final_text LIKE ? ESCAPE '\'"#)
    }

    /// `%`, `_` and `\` in what Jake typed match themselves.
    var bindings: [SQLValue] {
        guard let query else { return [] }
        let escaped = query.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_")
        return [.text("%\(escaped)%")]
    }
}

public struct DaySection: Sendable, Hashable {
    /// Year, month and day in the reader's calendar.
    public let day: DateComponents
    public internal(set) var count: Int
    /// Local midnight that starts the day.
    let startMs: Int64
    let newestMs: Int64
    var oldestMs: Int64
    /// The search that made this section, so its pages match its count.
    let query: String?
}

/// One table row: exactly what the row view draws.
public struct HistoryRow: Sendable, Hashable {
    public let id: DictationID
    public let startedAt: Date
    public let finalText: String?
    public let status: DictationStatus
    /// Grey text shows "cleanup rejected" (and friends) from this.
    public let cleanup: CleanupOutcome?
    public let model: SpeechModel?
    public let lag: Duration?
    public let pinned: Bool
    public let hasAudio: Bool
}

extension HistoryRow {
    /// The columns `init?(row:)` reads, in order. The list and the detail read the same ones.
    static let columns = "id, started_at, final_text, status, cleanup, model, lag_ms, pinned, audio_storage"

    init?(row: Row) {
        guard let id = row.text(0).flatMap(DictationID.init(column:)),
              let status = row.text(3).flatMap(DictationStatus.init(rawValue:)) else { return nil }
        self.init(id: id, startedAt: Date(unixMs: row.int(1) ?? 0), finalText: row.text(2), status: status,
                  cleanup: row.text(4).flatMap(CleanupOutcome.init(column:)), model: row.text(5).flatMap(SpeechModel.init(id:)),
                  lag: row.int(6).map { .milliseconds($0) }, pinned: row.int(7) == 1,
                  hasAudio: row.text(8) == AudioStorage.onDisk.rawValue)
    }
}

public struct HistoryDetail: Sendable {
    public let row: HistoryRow
    /// Model and cleaned text. Final text is `row.finalText` (History materializes it).
    public let versions: TextVersions?
    /// Every engine's run, oldest first: the winner and the losers.
    public let attempts: [AttemptRecord]
    /// What each Retry replaced, newest first.
    public let earlier: [EarlierVersion]
}

/// The text a Retry replaced, as it was then: Fixes made on it show in `final`.
public struct EarlierVersion: Sendable, Hashable {
    public let cleaned: String
    public let final: String
    /// The engine that heard it. nil for one this build does not know.
    public let model: SpeechModel?
    public let replacedAt: Date
}
