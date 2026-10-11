public import Foundation
public import LexiconDomain
import SQLiteKit

/// The History window's read side. Its own read-only connection (WAL allows a
/// reader beside the writer), confined to the main thread, opened when the
/// window opens and closed when it closes, so a closed window costs nothing.
///
/// Access pattern (NSTableView asks only for rows on screen): the table's flat
/// index is [day header, rows..., day header, rows...]. `sections` reads only
/// the `started_at` index (plus the table for the search match) and buckets it
/// into local days in Swift, so the calendar decides where a day ends, DST
/// included. Rows are then fetched a page at a time within one day (its
/// `started_at` range plus a small OFFSET). Opening the window costs one pass
/// over the time index plus one page, whatever the History size.
@MainActor
public final class HistoryReader {
    /// nil until the first Dictation creates `history.sqlite`: an empty History.
    private let db: Database?
    private let calendar: Calendar

    /// `calendar` decides the day buckets; tests pass a fixed time zone.
    public init(paths: AppPaths, calendar: Calendar = .current) throws {
        let file = paths.root.appending(path: "history.sqlite")
        db = FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
            ? try Database(at: file, mode: .readOnly, migrations: []) : nil
        self.calendar = calendar
    }

    /// Changes whenever the writer commits, so the window reloads only when there is something new.
    public var version: Int { db?.dataVersion ?? 0 }

    /// Newest day first. `matching` is a plain-text, case-insensitive search over
    /// final text (LIKE; FTS5 only if measured slow: #4). Blank means everything.
    public func sections(matching query: String?) -> [DaySection] {
        guard let db else { return [] }
        let filter = Filter(query)
        let times = (try? db.query("""
            SELECT started_at FROM dictation WHERE \(filter.sql) ORDER BY started_at DESC
            """, filter.bindings)) ?? []
        var sections: [DaySection] = []
        var day = Int64.max..<Int64.max
        for row in times {
            let ms = row.int(0) ?? 0
            if !day.contains(ms) {
                let start = calendar.startOfDay(for: Date(unixMs: ms))
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
                day = start.unixMs..<end.unixMs
                sections.append(DaySection(day: calendar.dateComponents([.year, .month, .day], from: start),
                                           count: 0, newestMs: ms, oldestMs: ms, query: filter.query))
            }
            sections[sections.count - 1].count += 1
            sections[sections.count - 1].oldestMs = ms
        }
        return sections
    }

    /// Newest first within the day.
    public func rows(in section: DaySection, offsets: Range<Int>) -> [HistoryRow] {
        guard let db, !offsets.isEmpty else { return [] }
        let filter = Filter(section.query)
        let rows = (try? db.query("""
            SELECT id, started_at, final_text, status, cleanup, model, lag_ms, pinned, audio_storage
            FROM dictation WHERE started_at BETWEEN ? AND ? AND \(filter.sql)
            ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?
            """, [.int(section.oldestMs), .int(section.newestMs)] + filter.bindings
                + [.int(Int64(offsets.count)), .int(Int64(offsets.lowerBound))])) ?? []
        return rows.compactMap(HistoryRow.init(row:))
    }

    /// "Show versions": model, cleaned, final, plus every Fix and attempt.
    public func detail(_ id: DictationID) -> HistoryDetail? { fatalError("not implemented") }

    /// For the play button (AVAudioPlayer). nil when audio was removed.
    public func audioURL(_ id: DictationID) -> URL? { fatalError("not implemented") }
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
    public let insertion: InsertionReceipt?
    public let fixes: [Fix]
    public let attempts: [AttemptRecord]
}
