public import Foundation
public import LexiconDomain
import SQLiteKit
import AudioCapture

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
    /// Capture started (first audio). Row created as `.recording`; file already exists.
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
    case pinned(DictationID, Bool)
    /// Delete one Dictation: text and audio. Ignored while `status.isInFlight`.
    case deleted(DictationID)
}

/// A Dictation the last run left unfinished, handed to the Conductor to transcribe.
/// It carries no insertion target, so it cannot be typed (#4: recovered text is never typed).
public struct UnfinishedDictation: Sendable {
    public let id: DictationID
    public let audio: URL
    public let purpose: DictationPurpose
    /// It was waiting for the network before the restart.
    public let wasWaiting: Bool
}

/// Sole owner of `history.sqlite` and of the audio files' lifecycle (path,
/// finalize after a crash, retention, delete). AudioCapture writes a file's
/// bytes only while its LiveCapture is open.
///
/// Writes never block a caller: `record` enqueues onto one serial writer queue
/// (FIFO, so events about one Dictation apply in order). The fn-up path never
/// waits on SQLite. Reads that the Conductor needs are async on the same queue;
/// the History window reads through its own connection (`HistoryReader`).
public final class HistoryStore: @unchecked Sendable {
    /// Opens `<root>/history.sqlite` and `<root>/audio/` (this module names both).
    public init(paths: AppPaths) throws { fatalError("not implemented") }

    /// `audio/<id>.caf`. The only code that names audio files.
    public func audioURL(for id: DictationID) -> URL { fatalError("not implemented") }

    /// Non-blocking, ordered, idempotent. Lost only if the app dies before the
    /// queue drains, which recovery handles because the audio file is the truth.
    public func record(_ event: DictationEvent) { fatalError("not implemented") }

    /// Launch. Finalizes open CAFs, adopts audio files with no row, deletes files
    /// whose row says deleted, marks rows whose audio is missing as failed, moves
    /// rows left in `.ready` (crashed mid-paste) to `.notInserted(.interrupted)` so
    /// they are never typed twice, sets
    /// `origin = recovered` on every row it hands back (so `.textReady` lands them
    /// as `.recovered`, never typed), then returns what still needs text.
    /// Idempotent: running it twice returns the same list and changes nothing the
    /// second time. See RecoveryPlan.
    public func recover() async -> [UnfinishedDictation] { fatalError("not implemented") }

    /// RAM copy of a Dictation's audio, for retry. nil once retention removed it.
    public func clip(_ id: DictationID) async -> AudioClip? { fatalError("not implemented") }

    /// Paste-last: newest Dictation whose status has text, and its final text.
    public func newestText() async -> (DictationID, String)? { fatalError("not implemented") }

    public func dictation(_ id: DictationID) async -> DictationRecord? { fatalError("not implemented") }

    /// Recently inserted Dictations, newest first, for matching a hook prompt to its Dictation.
    public func recentInserted(within: Duration) async -> [DictationRecord] { fatalError("not implemented") }

    /// Where a Dictation's text last landed. The durable key Re-speak and Hand fix
    /// use once AppText's live references are gone (`TargetApp.reattach`).
    public func receipt(for id: DictationID) async -> InsertionReceipt? { fatalError("not implemented") }

    /// After every write that a window would show. The History window reloads those rows.
    public var changes: AsyncStream<DictationID> { fatalError("not implemented") }

    /// Waits until every event recorded so far is applied (tests, eval, quit).
    public func flush() async { fatalError("not implemented") }
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
    /// The one switch from events to rows, run on the writer queue inside one
    /// transaction per event. For every status-moving event:
    ///
    ///     let stored = SELECT status, origin FROM dictation WHERE id = ?
    ///     let next = event's target status (below)
    ///     guard Self.admits(next, from: stored) else { return }   // replay or race: no-op
    ///
    /// Targets: began -> .recording (INSERT OR IGNORE); audioEnded -> .transcribing;
    /// textReady -> afterTextReady(typing:, origin: stored origin, previous: stored);
    /// delivered -> .inserted; notInserted -> .notInserted; waiting -> .waiting;
    /// failed -> .failed. Not status-moving: attempted,
    /// fixRecorded, fixVerdict, pinned; deleted is refused while `isInFlight`;
    /// discarded only while `.recording`.
    func apply(_ event: DictationEvent, in db: Database) throws {
        // TODO: exhaustive switch over `event`, as above; each case one transaction.
        fatalError("not implemented")
    }

    /// The gate every status-moving event passes. No stored row: only `began` may create one.
    static func admits(_ next: DictationStatus, from stored: DictationStatus?) -> Bool {
        guard let stored else { return next == .recording }
        return stored.canMove(to: next)
    }
}
