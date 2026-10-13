public import Foundation
public import LexiconDomain
import SQLiteKit
import AudioCapture
import os

/// Everything that happens to a Dictation that History must remember. The ONE
/// write API: callers (the Conductor, Fixes, the UI) describe what happened;
/// History alone turns it into rows. The exhaustive switch in `apply` is where
/// every rule about rows lives (status moves, final text, delete refusal).
///
/// Every event is idempotent. Status-moving events apply only when
/// `DictationStatus.canMove(to:)` allows the move from the STORED status, so a
/// replayed or racing event is a no-op by construction. Rows are inserted with
/// INSERT OR IGNORE by id; deletes tolerate absence.
public enum DictationEvent: Sendable {
    /// fn-down, recorded while the mic starts. Row created as `.recording`; the file
    /// follows once capture runs, and never comes when the mic can't start.
    case began(DictationID, origin: DictationOrigin, purpose: DictationPurpose, at: Date, app: AppContext)
    /// Moves `.recording` -> `.transcribing`.
    case audioEnded(DictationID, AudioSummary)
    /// One engine's result (winner or loser). Rows in `attempt`.
    case attempted(DictationID, AttemptRecord)
    /// Text produced and cleaned. Recorded BEFORE the text is typed, so it is queued
    /// for disk first. Sets model and cleaned text and the cleanup outcome, and
    /// recomputes final text from cleaned text plus any Fix rows (never a blind
    /// reset, so a replay cannot erase a Fix). Status: `afterTextReady(typing:...)`
    /// from the stored status and origin: `.ready` when the text is about to be typed.
    case textReady(DictationID, TextVersions, cleanup: CleanupOutcome, model: SpeechModel, typing: Bool)
    /// History's Retry got text. Keeps the row's cleaned and final text (if it has any)
    /// as an earlier version keyed by `version`, minted once per Retry, then applies
    /// as `.textReady` with `typing: false`, in one transaction.
    case retried(DictationID, TextVersions, cleanup: CleanupOutcome, model: SpeechModel, version: UUID)
    /// The text was typed (live insert, late insert, or paste-last). Writes the
    /// `insertion` row (latest insertion wins) and moves the status to `.inserted`.
    /// `lag`: fn-up -> Cmd-V posted; nil for paste-last.
    case delivered(DictationID, InsertionReceipt, lag: Duration?)
    /// The insert right after `.textReady` was held (focus moved, typed since, no field).
    case notInserted(DictationID, NotInsertedReason)
    case waiting(DictationID, reason: String)
    case failed(DictationID, reason: String)
    /// A stray tap: never a Dictation. Removes row and file (only while `.recording`).
    case discarded(DictationID)
    /// Inserts the fix row and updates final text, in one transaction.
    case fixRecorded(Fix)
    case fixVerdict(FixID, FixVerdict)
    /// Test set pin. Pinning keeps the audio, so only a Dictation with its whole audio on disk takes it; unpinning always applies.
    case pinned(DictationID, Bool)
    /// Delete one Dictation: text and audio. Ignored while `status.isInFlight`.
    case deleted(DictationID)
}

/// Sole owner of `history.sqlite` and of the audio files' lifecycle (path,
/// finalize after a crash, retention, delete). AudioCapture writes a file's
/// bytes only while its LiveCapture is open.
///
/// Writes never block a caller: `record` enqueues onto one serial writer queue
/// (FIFO, so events about one Dictation apply in order). The fn-up path never
/// waits on SQLite. Reads that the Conductor needs are async on the same queue;
/// the History window reads through its own connection (`HistoryReader`).
///
/// `@unchecked Sendable`: the only mutable state is `db`, touched only on `queue`
/// after init returns; everything else is immutable or itself Sendable.
public final class HistoryStore: @unchecked Sendable {
    private let paths: AppPaths
    /// Rows and files from before this are an earlier run's: launch recovery's to finish.
    let openedAt = Date()
    private let queue = DispatchQueue(label: "lexicon.history.writer", qos: .userInitiated)
    private let db: Database
    private let changeStream: AsyncStream<DictationID>
    let changed: AsyncStream<DictationID>.Continuation
    let log = Logger(subsystem: "Lexicon", category: "History")

    /// Opens `<root>/history.sqlite` and `<root>/audio/` (this module names both).
    public init(paths: AppPaths) throws {
        self.paths = paths
        try FileManager.default.createDirectory(at: Self.audioFolder(in: paths), withIntermediateDirectories: true)
        db = try Database(at: paths.root.appending(path: "history.sqlite"), mode: .readWrite,
                          migrations: HistorySchema.migrations)
        try db.transaction { try HistorySchema.syncDerivedIndexes(in: $0) }
        // Bounded: with no window open, nobody reads it.
        (changeStream, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1_024))
    }

    deinit { changed.finish() }

    /// `<root>/audio/`, where every Dictation's audio lives.
    static func audioFolder(in paths: AppPaths) -> URL {
        paths.root.appending(path: "audio", directoryHint: .isDirectory)
    }

    /// `audio/<id>.caf`. The only code that names audio files. HistoryReader calls it too.
    static func audioURL(for id: DictationID, in paths: AppPaths) -> URL {
        audioFolder(in: paths).appending(path: "\(id).caf", directoryHint: .notDirectory)
    }

    var audioFolder: URL { Self.audioFolder(in: paths) }

    public func audioURL(for id: DictationID) -> URL {
        Self.audioURL(for: id, in: paths)
    }

    /// Non-blocking, ordered, idempotent. An event is lost if the app dies before
    /// the queue drains, or if SQLite fails it (disk full, I/O error: logged, not
    /// retried). Recovery covers both, because the audio file is the truth.
    public func record(_ event: DictationEvent) {
        queue.async { [self] in
            do {
                guard let applied = try db.transaction({ try apply(event, in: $0) }) else { return }
                if applied.dropAudio { try dropAudio(applied.id) }
                if applied.changed { changed.yield(applied.id) }
            } catch {
                // No Dictation text in the log: the event's name, and SQLite's error privately.
                let name = Mirror(reflecting: event).children.first?.label ?? "event"
                log.error("History dropped .\(name, privacy: .public): \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Audio retention (see `Retention`). Rows keep their text; their audio reads
    /// `.expired`. Marks every expiring row in one commit, then unlinks the files,
    /// as Delete does, so a crash in between leaves files recovery deletes, never
    /// orphans it would adopt and transcribe again.
    public func sweepAudio(now: Date) async {
        do {
            try await read { [self] db in
                let expired = try db.transaction { db in
                    try Retention.expire(in: db, now: now, bytes: { Self.bytes(at: audioURL(for: $0)) })
                }
                for id in expired {
                    // One file that won't go must not strand the rest; launch recovery unlinks it later.
                    do {
                        try removeAudioFile(id)
                    } catch {
                        log.error("Retention left an audio file: \(String(describing: error), privacy: .private)")
                    }
                    changed.yield(id)
                }
            }
        } catch {
            log.error("Audio retention failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// 0 for a missing file: it takes no space, and its row can still be marked.
    private static func bytes(at url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Whole audio of a Dictation, for Retry. nil unless all of it is on disk (aged out, deleted, or a RAM-only capture's partial file).
    public func clip(_ id: DictationID) async -> AudioClip? {
        let storage = try? await read { db in
            try db.query("SELECT audio_storage FROM dictation WHERE id = ?", [.text(id.description)]).first?.text(0)
        }
        guard storage == AudioStorage.onDisk.rawValue else { return nil }
        // The CAF read is slow for a long Dictation, so it runs off the writer queue.
        let url = audioURL(for: id)
        return await Task.detached { try? CAFFile.read(url) }.value
    }

    /// Paste-last: newest Dictation whose status has text, and its final text.
    public func newestText() async -> (DictationID, String)? { fatalError("not implemented") }

    public func dictation(_ id: DictationID) async -> DictationRecord? {
        try? await read { db in
            try db.query("SELECT \(DictationRecord.columns) FROM dictation WHERE id = ?", [.text(id.description)])
                .first.flatMap(DictationRecord.init(row:))
        }
    }

    /// Recently inserted Dictations, newest first, for matching a hook prompt to its Dictation.
    public func recentInserted(within: Duration) async -> [DictationRecord] { fatalError("not implemented") }

    /// Where a Dictation's text last landed. The durable key Re-speak and Hand fix
    /// use once AppText's live references are gone (`TargetApp.reattach`).
    public func receipt(for id: DictationID) async -> InsertionReceipt? {
        try? await read { db in
            try db.query("""
                SELECT app_bundle_id, field_fingerprint, caret_after, context_before, context_after, inserted_at
                FROM insertion WHERE dictation_id = ?
                """, [.text(id.description)]).first.map { row in
                InsertionReceipt(appBundleID: row.text(0), fieldFingerprint: row.text(1), caretAfter: row.int(2).map(Int.init),
                                 contextBefore: row.text(3) ?? "", contextAfter: row.text(4) ?? "",
                                 insertedAt: Date(unixMs: row.int(5) ?? 0))
            }
        }
    }

    /// After every write that a window would show. The History window reloads those rows.
    /// One reader: the stream is shared, so a second iterator would split the ids.
    public var changes: AsyncStream<DictationID> { changeStream }

    /// Waits until every event recorded so far is applied (tests, eval, quit).
    public func flush() async {
        await withCheckedContinuation { done in queue.async { done.resume() } }
    }

    /// Runs `body` on the writer queue, after every event recorded before it.
    func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in
            queue.async { [self] in done.resume(with: Result { try body(db) }) }
        }
    }

    /// The second half of a delete: the row already says `deleted` and is committed,
    /// so a crash from here on leaves a row, and maybe its file, that recovery drops
    /// (`deleteGarbage`), never an orphan it would adopt and transcribe again.
    func dropAudio(_ id: DictationID) throws {
        try removeAudioFile(id)
        try db.transaction {
            try $0.execute("DELETE FROM dictation WHERE id = ? AND audio_storage = ?",
                           [.text(id.description), .text(AudioStorage.deleted.rawValue)])
        }
    }

    /// Already gone is fine: every caller has committed the row's mark first.
    func removeAudioFile(_ id: DictationID) throws {
        do {
            try FileManager.default.removeItem(at: audioURL(for: id))
        } catch CocoaError.fileNoSuchFile {}
    }
}

/// A Dictation as other modules see it. Plain values; no SQL types.
public struct DictationRecord: Sendable, Hashable {
    public let id: DictationID
    public let startedAt: Date
    public let origin: DictationOrigin
    public let purpose: DictationPurpose
    public let status: DictationStatus
    public let versions: TextVersions?
    /// After Fixes. Materialized only by History (cleaned text plus Fix rows).
    public let finalText: String?
    public let cleanup: CleanupOutcome?
    public let model: SpeechModel?
    public let lag: Duration?
    public let app: AppContext
    public let pinned: Bool
    public let audio: AudioStorage
}

extension HistoryStore {
    /// What one applied event did, for the work that follows its commit.
    struct Applied {
        let id: DictationID
        /// Something a window shows changed. A replay changes nothing, so it notifies nobody.
        var changed: Bool
        /// The row is marked deleted: unlink the file, then drop the row.
        var dropAudio = false
    }

    /// The one switch from events to rows, run on the writer queue inside one
    /// transaction per event. For every status-moving event:
    ///
    ///     let stored = SELECT status, origin FROM dictation WHERE id = ?
    ///     let next = event's target status (below)
    ///     guard Self.admits(next, from: stored) else { return }   // replay or race: no-op
    ///
    /// Targets: began -> .recording (INSERT OR IGNORE); audioEnded -> .transcribing;
    /// textReady -> afterTextReady(typing:, origin: stored origin, previous: stored); retried -> as
    /// textReady(typing: false), keeping the replaced text first;
    /// delivered -> .inserted; notInserted -> .notInserted; waiting -> .waiting;
    /// failed -> .failed. Not status-moving: attempted,
    /// fixRecorded, fixVerdict, pinned (true only with the audio on disk); deleted is refused while `isInFlight`;
    /// discarded only while `.recording`.
    ///
    /// A same-state move keeps the status and rewrites the event's fields, so a
    /// replay writes what is already there and changes nothing. nil: no such row.
    func apply(_ event: DictationEvent, in db: Database) throws -> Applied? {
        guard let id = try Self.subject(of: event, in: db) else { return nil }
        let key = SQLValue.text(id.description)
        let before = try db.query("SELECT * FROM dictation WHERE id = ?", [key])
        let stored = before.first.flatMap(Stored.init(row:))
        var wroteChild = false
        var dropAudio = false

        /// Moves the row to `next` if the rules allow it from the stored status,
        /// then sets `fields` too. Clears the reason whenever the status changes.
        func move(to next: DictationStatus, setting fields: [(String, SQLValue)] = []) throws -> Bool {
            guard let stored, Self.admits(next, from: stored.status) else { return false }
            var assignments = fields
            if !fields.contains(where: { $0.0 == "status_reason" }) {
                assignments.append(("status_reason", stored.status == next ? .optional(stored.reason) : .null))
            }
            assignments.append(("status", .text(next.rawValue)))
            try db.execute("UPDATE dictation SET \(assignments.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE id = ?",
                           assignments.map(\.1) + [key])
            return true
        }

        /// The text and status move `.textReady` makes, and `.retried` after keeping what it replaces.
        func setText(_ versions: TextVersions, cleanup: CleanupOutcome, model: SpeechModel, typing: Bool,
                     from stored: Stored) throws {
            if try move(to: Self.afterTextReady(typing: typing, from: stored), setting: [
                ("model_text", .text(versions.model)),
                ("cleaned_text", .text(versions.cleaned)),
                ("cleanup", .text(try cleanup.column())),
                ("model", .text(model.id)),
            ]) {
                // Recomputed from cleaned text plus Fix rows, never reset: a replay cannot erase a Fix.
                try Self.materializeFinalText(id, in: db)
            }
        }

        switch event {
        case .began(_, let origin, let purpose, let at, let app):
            let respeakOf: SQLValue = if case .respeak(let of) = purpose { .text(of.description) } else { .null }
            // A Re-speak of a Dictation deleted meanwhile is still saved (respeak_of NULL), never lost to the FK.
            try db.execute("""
                INSERT OR IGNORE INTO dictation
                  (id, started_at, origin, purpose, respeak_of, status, audio_storage, app_bundle_id, app_title)
                VALUES (?, ?, ?, ?, (SELECT id FROM dictation WHERE id = ?), ?, ?, ?, ?)
                """, [key, .int(at.unixMs), .text(origin.rawValue), .text(purpose.column), respeakOf,
                      .text(DictationStatus.recording.rawValue), .text(AudioStorage.onDisk.rawValue),
                      .optional(app.bundleID), .optional(app.appName)])

        case .audioEnded(_, let summary):
            _ = try move(to: .transcribing, setting: [
                ("ended_at", .int((before.first?.int(1) ?? 0) + summary.duration.ms)),
                ("audio_ms", .int(summary.duration.ms)),
                ("start_gap_ms", .optional(summary.startGap?.ms)),
                ("device", .optional(summary.deviceName)),
                ("audio_storage", .text(summary.storage.rawValue)),
            ])

        case .attempted(_, let attempt):
            guard stored != nil else { return nil }
            // No id on the record: an identical attempt is the same attempt replayed.
            let fields: [SQLValue] = [key, .text(attempt.model.id), .text(attempt.result.rawValue), .optional(attempt.text),
                                      .optional(attempt.latency?.ms), .optional(attempt.error)]
            try db.execute("""
                INSERT INTO attempt (dictation_id, model, result, text, latency_ms, error, at)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE NOT EXISTS (
                  SELECT 1 FROM attempt WHERE dictation_id = ?1 AND model = ?2 AND result = ?3
                    AND text IS ?4 AND latency_ms IS ?5 AND error IS ?6)
                """, fields + [.int(Date().unixMs)])
            wroteChild = db.changes > 0

        case .textReady(_, let versions, let cleanup, let model, let typing):
            guard let stored else { return nil }
            try setText(versions, cleanup: cleanup, model: model, typing: typing, from: stored)

        case .retried(_, let versions, let cleanup, let model, let version):
            guard let stored else { return nil }
            // Its version saved means this Retry applied: a replay after a newer Retry must not bring its text back.
            guard try db.query("SELECT 1 FROM earlier_version WHERE id = ?", [.text(version.uuidString)]).isEmpty else {
                return nil
            }
            // Before the text it replaces is overwritten, and only if the Retry's text lands.
            if Self.admits(Self.afterTextReady(typing: false, from: stored), from: stored.status) {
                try db.execute("""
                    INSERT INTO earlier_version (id, dictation_id, model, cleaned_text, final_text, replaced_at)
                    SELECT ?, id, model, cleaned_text, coalesce(final_text, cleaned_text), ? FROM dictation
                    WHERE id = ? AND cleaned_text IS NOT NULL
                    """, [.text(version.uuidString), .int(Date().unixMs), key])
                wroteChild = db.changes > 0
            }
            try setText(versions, cleanup: cleanup, model: model, typing: false, from: stored)

        case .delivered(_, let receipt, let lag):
            // Latest insertion wins; paste-last (lag nil) keeps the live insert's lag.
            if try move(to: .inserted, setting: lag.map { [("lag_ms", .int($0.ms))] } ?? []) {
                let insertion = "SELECT * FROM insertion WHERE dictation_id = ?"
                let previous = try db.query(insertion, [key])
                try db.execute("""
                    INSERT OR REPLACE INTO insertion
                      (dictation_id, app_bundle_id, field_fingerprint, caret_after, context_before, context_after, inserted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [key, .optional(receipt.appBundleID), .optional(receipt.fieldFingerprint),
                          .optional(receipt.caretAfter.map(Int64.init)), .text(receipt.contextBefore),
                          .text(receipt.contextAfter), .int(receipt.insertedAt.unixMs)])
                wroteChild = try db.query(insertion, [key]) != previous  // REPLACE always counts a change
            }

        case .notInserted(_, let reason):
            _ = try move(to: .notInserted, setting: [("status_reason", .text(reason.rawValue))])
        case .waiting(_, let reason):
            _ = try move(to: .waiting, setting: [("status_reason", .text(reason))])
        case .failed(_, let reason):
            _ = try move(to: .failed, setting: [("status_reason", .text(reason))])

        case .discarded:
            guard stored?.status == .recording else { return nil }
            dropAudio = try Self.markAudioDeleted(key, in: db)

        case .deleted:
            guard let stored, !stored.status.isInFlight else { return nil }
            dropAudio = try Self.markAudioDeleted(key, in: db)

        case .fixRecorded(let fix):
            guard stored != nil else { return nil }
            try db.execute("""
                INSERT OR IGNORE INTO fix (id, dictation_id, kind, source, text_before, text_after, verdict, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(fix.id.uuid.uuidString), key, .text(fix.kind.rawValue), .text(fix.source.rawValue),
                      .text(fix.before), .text(fix.after), .text(fix.verdict.rawValue), .int(fix.at.unixMs)])
            wroteChild = db.changes > 0
            if wroteChild { try Self.materializeFinalText(id, in: db) }

        case .fixVerdict(let fixID, let verdict):
            try db.execute("UPDATE fix SET verdict = ? WHERE id = ? AND verdict IS NOT ?",
                           [.text(verdict.rawValue), .text(fixID.uuid.uuidString), .text(verdict.rawValue)])
            wroteChild = db.changes > 0
            if wroteChild { try Self.materializeFinalText(id, in: db) }

        case .pinned(_, let pinned):
            // Pinning keeps audio for the Test set, so a row whose audio is partial or gone
            // stays unpinned. The column can say onDisk for a file a crash lost, so check both.
            if pinned, FileManager.default.fileExists(atPath: audioURL(for: id).path(percentEncoded: false)) {
                try db.execute("UPDATE dictation SET pinned = 1 WHERE id = ? AND audio_storage = ?",
                               [key, .text(AudioStorage.onDisk.rawValue)])
            } else if !pinned {
                try db.execute("UPDATE dictation SET pinned = 0 WHERE id = ?", [key])
            }
        }

        let after = try db.query("SELECT * FROM dictation WHERE id = ?", [key])
        return Applied(id: id, changed: wroteChild || after != before, dropAudio: dropAudio)
    }

    /// Where text moves a row. Recovered audio is never typed, whatever the caller says (#4).
    private static func afterTextReady(typing: Bool, from stored: Stored) -> DictationStatus {
        DictationStatus.afterTextReady(typing: typing && stored.origin != .recovered, origin: stored.origin,
                                       previous: stored.status)
    }

    /// The gate every status-moving event passes. No stored row: only `began` may create one.
    static func admits(_ next: DictationStatus, from stored: DictationStatus?) -> Bool {
        guard let stored else { return next == .recording }
        return stored.canMove(to: next)
    }

    /// The Dictation an event is about. A Fix verdict names only its Fix.
    private static func subject(of event: DictationEvent, in db: Database) throws -> DictationID? {
        switch event {
        case .began(let id, _, _, _, _), .audioEnded(let id, _), .attempted(let id, _), .textReady(let id, _, _, _, _),
             .retried(let id, _, _, _, _),
             .delivered(let id, _, _), .notInserted(let id, _), .waiting(let id, _), .failed(let id, _),
             .discarded(let id), .pinned(let id, _), .deleted(let id):
            return id
        case .fixRecorded(let fix):
            return fix.dictation
        case .fixVerdict(let fixID, _):
            return try db.query("SELECT dictation_id FROM fix WHERE id = ?", [.text(fixID.uuid.uuidString)])
                .first?.text(0).flatMap(DictationID.init(column:))
        }
    }

    /// Final text = cleaned text with every Fix not rejected applied in the order
    /// they were made. A Fix replaces the first occurrence of its `before`; a Fix
    /// whose `before` is no longer there changes nothing. The only writer of `final_text`.
    private static func materializeFinalText(_ id: DictationID, in db: Database) throws {
        let key = SQLValue.text(id.description)
        guard var text = try db.query("SELECT cleaned_text FROM dictation WHERE id = ?", [key]).first?.text(0) else { return }
        let fixes = try db.query("""
            SELECT text_before, text_after FROM fix WHERE dictation_id = ? AND verdict != ? ORDER BY at, rowid
            """, [key, .text(FixVerdict.rejected.rawValue)])
        for fix in fixes {
            guard let before = fix.text(0), !before.isEmpty, let range = text.range(of: before) else { continue }
            text.replaceSubrange(range, with: fix.text(1) ?? "")
        }
        try db.execute("UPDATE dictation SET final_text = ? WHERE id = ?", [.text(text), key])
    }

    /// First half of a delete: commit the mark before the file goes (see `dropAudio`).
    /// The text goes now too, so a crash before the row is dropped leaves no text behind.
    private static func markAudioDeleted(_ key: SQLValue, in db: Database) throws -> Bool {
        try db.execute("""
            UPDATE dictation SET audio_storage = ?, model_text = NULL, cleaned_text = NULL, final_text = NULL WHERE id = ?
            """, [.text(AudioStorage.deleted.rawValue), key])
        // The rows that hold its text too (engine attempts, Fixes, the words around the paste, what Retries replaced).
        for table in ["attempt", "fix", "insertion", "earlier_version"] {
            try db.execute("DELETE FROM \(table) WHERE dictation_id = ?", [key])
        }
        return true
    }
}

/// The columns every status move is decided from.
private struct Stored {
    let status: DictationStatus
    let origin: DictationOrigin
    let reason: String?

    /// From `SELECT *`: column order is the migration's.
    init?(row: Row) {
        guard let status = row.text(6).flatMap(DictationStatus.init(rawValue:)),
              let origin = row.text(3).flatMap(DictationOrigin.init(rawValue:)) else { return nil }
        self.status = status
        self.origin = origin
        self.reason = row.text(7)
    }
}
