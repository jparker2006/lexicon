public import Foundation
public import LexiconDomain
import SQLiteKit

/// The History window's read side. Its own read-only connection (WAL allows a
/// reader beside the writer), confined to the main thread, opened when the
/// window opens and closed when it closes, so a closed window costs nothing.
///
/// Access pattern (NSTableView asks only for rows on screen): the table's flat
/// index is [day header, rows..., day header, rows...]. `sections` gives each
/// day's count (one indexed GROUP BY); a flat index maps to (day, offset) by
/// binary search over cumulative counts; rows are fetched in pages of 50 within
/// one day (`started_at` range + small OFFSET), cached by page. Opening the
/// window costs one GROUP BY plus one page, whatever the History size.
@MainActor
public final class HistoryReader {
    public init(paths: AppPaths) throws { fatalError("not implemented") }

    /// Newest day first. `matching` is a plain-text search over final text
    /// (LIKE; FTS5 only if measured slow: #4).
    public func sections(matching query: String?) -> [DaySection] { fatalError("not implemented") }

    public func rows(in section: DaySection, offsets: Range<Int>) -> [HistoryRow] { fatalError("not implemented") }

    /// "Show versions": model, cleaned, final, plus every Fix and attempt.
    public func detail(_ id: DictationID) -> HistoryDetail? { fatalError("not implemented") }

    /// For the play button (AVAudioPlayer). nil when audio was removed.
    public func audioURL(_ id: DictationID) -> URL? { fatalError("not implemented") }
}

public struct DaySection: Sendable, Hashable {
    public let day: DateComponents
    public let count: Int
    let newestMs: Int64
    let oldestMs: Int64
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

public struct HistoryDetail: Sendable {
    public let row: HistoryRow
    /// Model and cleaned text. Final text is `row.finalText` (History materializes it).
    public let versions: TextVersions?
    public let insertion: InsertionReceipt?
    public let fixes: [Fix]
    public let attempts: [AttemptRecord]
}
