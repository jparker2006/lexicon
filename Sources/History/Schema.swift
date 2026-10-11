import LexiconDomain

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

    /// `'recording', 'transcribing', ...` for every status where `property` equals `value`.
    static func sqlList(_ property: (DictationStatus) -> Bool, is value: Bool) -> String {
        DictationStatus.allCases.filter { property($0) == value }.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }
}

/// Pure crash recovery: rows and files in, actions out. Tested without disk.
/// Converges: applying the actions and planning again yields only `.transcribe`
/// for the same ids (which the Conductor runs; their `.textReady` ends them).
enum RecoveryPlan {
    struct RowState: Sendable, Hashable {
        let id: DictationID
        let status: DictationStatus
        let audio: AudioStorage
    }
    enum FileState: Sendable, Hashable { case open, closed, unreadable }

    enum Action: Sendable, Hashable {
        case finalize(DictationID)                 // CAF still open: write its real size
        case adoptOrphan(DictationID)              // file with no row: insert row, origin recovered
        case deleteGarbage(DictationID)            // row says deleted (crash between mark and unlink)
        case markFailed(DictationID, String)       // in-flight row, no readable audio
        case transcribe(DictationID, wasWaiting: Bool)
    }

    static func plan(rows: [RowState], files: [DictationID: FileState]) -> [Action] {
        // TODO:
        // - for each file: no row -> [finalize if open, adoptOrphan, transcribe]
        // - row.audio == .deleted && file exists -> deleteGarbage
        // - row whose status is not terminal (!status.isTerminal):
        //     file open -> finalize + transcribe; closed -> transcribe; missing/unreadable -> markFailed
        fatalError("not implemented")
    }
}

/// Audio retention (#4): rolling 14 days or 1 GB, oldest unpinned first; never a
/// Dictation whose status `needsAudio`; pinned audio kept forever and not counted
/// against the 1 GB. Mark the row deleted, commit, then unlink.
enum Retention {
    static let window: Duration = .seconds(14 * 24 * 3600)
    static let byteCap: Int64 = 1_000_000_000
    /// Generated, never hand-listed: the sweep's `WHERE status NOT IN (...)`.
    static var skippedStatuses: String { HistorySchema.sqlList(\.needsAudio, is: true) }
}
