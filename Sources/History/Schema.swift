import Foundation
import LexiconDomain
import SQLiteKit

/// history.sqlite. Append-only migrations. Enum-valued columns store the Swift
/// enum's rawValue; there are deliberately no CHECK lists to keep in sync, and
/// no status is ever listed by hand: anything that depends on a set of statuses
/// is generated from `DictationStatus` (see `derivedIndexes`, `Retention`).
enum HistorySchema {
    static let migrations: [String] = [
        """
        CREATE TABLE dictation (
          id            TEXT PRIMARY KEY,          -- DictationID; audio is audio/<id>.caf
          started_at    INTEGER NOT NULL,          -- unix ms
          ended_at      INTEGER,
          origin        TEXT NOT NULL,             -- DictationOrigin
          purpose       TEXT NOT NULL,             -- 'type' | 'respeak'
          respeak_of    TEXT REFERENCES dictation(id) ON DELETE SET NULL,
          status        TEXT NOT NULL,             -- DictationStatus
          status_reason TEXT,
          model_text    TEXT,
          cleaned_text  TEXT,
          final_text    TEXT,                      -- materialized ONLY by History: cleaned + Fix rows, same transaction
          cleanup       TEXT,                      -- CleanupOutcome, encoded by History ("cleanup rejected" in the window)
          model         TEXT,                      -- SpeechModel.id of the winning engine
          lag_ms        INTEGER,                   -- fn-up -> Cmd-V posted
          audio_ms      INTEGER,
          audio_storage TEXT NOT NULL,             -- AudioStorage
          start_gap_ms  INTEGER,
          device        TEXT,
          app_bundle_id TEXT,
          app_title     TEXT,
          pinned        INTEGER NOT NULL DEFAULT 0 -- Test set pin, kept forever
        );
        CREATE INDEX dictation_by_time ON dictation(started_at DESC);

        CREATE TABLE attempt (
          id            INTEGER PRIMARY KEY,
          dictation_id  TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
          model         TEXT NOT NULL,             -- SpeechModel.id
          result        TEXT NOT NULL,             -- AttemptRecord.Result
          text          TEXT,
          latency_ms    INTEGER,
          error         TEXT,
          at            INTEGER NOT NULL
        );
        CREATE INDEX attempt_by_dictation ON attempt(dictation_id);

        CREATE TABLE fix (
          id            TEXT PRIMARY KEY,          -- FixID: replaying the same Fix is a no-op
          dictation_id  TEXT NOT NULL REFERENCES dictation(id) ON DELETE CASCADE,
          kind          TEXT NOT NULL,             -- FixKind
          source        TEXT NOT NULL,             -- FixSource
          text_before   TEXT NOT NULL,
          text_after    TEXT NOT NULL,
          verdict       TEXT NOT NULL,             -- FixVerdict
          at            INTEGER NOT NULL
        );
        CREATE INDEX fix_by_dictation ON fix(dictation_id);

        -- Where the text last landed (InsertionReceipt). Written by `.delivered`; the
        -- durable key for Re-speak and Hand fix. Live AX references stay in AppText memory.
        CREATE TABLE insertion (
          dictation_id      TEXT PRIMARY KEY REFERENCES dictation(id) ON DELETE CASCADE,
          app_bundle_id     TEXT,
          field_fingerprint TEXT,                  -- opaque, minted by AppText
          caret_after       INTEGER,               -- UTF-16 offset after the paste
          context_before    TEXT NOT NULL,
          context_after     TEXT NOT NULL,
          inserted_at       INTEGER NOT NULL       -- unix ms
        );
        """,
        """
        -- Covering for the History window's day sections: a year of History is
        -- counted from this index alone, never reading the rows' text.
        DROP INDEX dictation_by_time;
        CREATE INDEX dictation_by_time ON dictation(started_at DESC, status, audio_storage);
        """,
        """
        -- Where a Fix's words start in the final text before it (UTF-16): the
        -- same words can appear twice, and a Fix belongs to one of them.
        ALTER TABLE fix ADD COLUMN text_location INTEGER;
        """,
    ]

    /// Indexes whose SQL is generated from Swift enums. Not migrations (a
    /// migration's text must never change): History compares each with
    /// `sqlite_master.sql` at open and drops and recreates it when it differs, so
    /// adding a status to `DictationStatus` updates the index with no SQL edit.
    static var derivedIndexes: [String] {
        [
            // What launch recovery scans: every status that is not terminal.
            "CREATE INDEX dictation_unfinished ON dictation(status) WHERE status IN (\(sqlList(\.isTerminal, is: false)))",
        ]
    }

    /// Recreates every derived index whose stored SQL differs from what the enum
    /// generates now. Run at open, inside one transaction.
    static func syncDerivedIndexes(in db: Database) throws {
        for sql in derivedIndexes {
            let name = sql.split(separator: " ")[2]
            let stored = try db.query("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [.text(String(name))])
            guard stored.first?.text(0) != sql else { continue }
            try db.execute("DROP INDEX IF EXISTS \(name)")
            try db.execute(sql)
        }
    }

    /// `'recording', 'transcribing', ...` for every status where `property` equals `value`.
    static func sqlList(_ property: (DictationStatus) -> Bool, is value: Bool) -> String {
        DictationStatus.allCases.filter { property($0) == value }.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }
}

/// Audio retention (#4): audio older than 14 days goes, then the oldest until
/// what is left fits in 1 GB. Text is kept forever. Never touched, and not
/// counted against the 1 GB: a Dictation whose status `needsAudio` (it still
/// waits for text, or for a manual Retry) and pinned audio (the Test set's).
enum Retention {
    static let window: Duration = .seconds(14 * 24 * 3600)
    static let byteCap: Int64 = 1_000_000_000
    /// Generated, never hand-listed: the sweep's `WHERE status NOT IN (...)`.
    static var skippedStatuses: String { HistorySchema.sqlList(\.needsAudio, is: true) }

    /// Marks the audio that goes as `.expired` and returns its ids, oldest first.
    /// A `.ramOnly` row counts too: its capture left a partial file on disk.
    /// The caller unlinks the files once this commits.
    static func expire(in db: Database, now: Date, bytes: (DictationID) -> Int64) throws -> [DictationID] {
        let candidates = try db.query("""
            SELECT id, started_at FROM dictation
            WHERE audio_storage IN (?, ?) AND pinned = 0 AND status NOT IN (\(skippedStatuses))
            ORDER BY started_at, id
            """, [.text(AudioStorage.onDisk.rawValue), .text(AudioStorage.ramOnly.rawValue)]).compactMap { row -> (id: DictationID, startedAt: Int64, bytes: Int64)? in
            guard let id = row.text(0).flatMap(DictationID.init(column:)) else { return nil }
            return (id, row.int(1) ?? 0, bytes(id))
        }
        let cutoff = now.unixMs - window.ms
        var total = candidates.reduce(0) { $0 + $1.bytes }
        var expired: [DictationID] = []
        for candidate in candidates where candidate.startedAt < cutoff || total > byteCap {
            expired.append(candidate.id)
            total -= candidate.bytes
        }
        for id in expired {
            try db.execute("UPDATE dictation SET audio_storage = ? WHERE id = ?",
                           [.text(AudioStorage.expired.rawValue), .text(id.description)])
        }
        return expired
    }
}
