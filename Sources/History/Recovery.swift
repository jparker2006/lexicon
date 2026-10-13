public import Foundation
public import LexiconDomain
import SQLiteKit
import AudioCapture

/// A Dictation the last run left unfinished, handed to the Conductor to transcribe.
/// It carries no insertion target, so it cannot be typed (#4: recovered text is never typed).
public struct UnfinishedDictation: Sendable {
    public let id: DictationID
    public let audio: URL
    public let purpose: DictationPurpose
    /// The app it was dictated into, for its words and Cleanup. `.unknown` for an
    /// audio file the last run never got to record a row for.
    public let app: AppContext
    /// It was waiting for an engine before the restart.
    public let wasWaiting: Bool
}

extension HistoryStore {
    /// Launch. Finalizes open CAFs, adopts audio files with no row, finishes a
    /// delete or a retention sweep a crash cut short, marks rows whose audio is
    /// missing as failed, moves rows left in `.ready` (crashed mid-paste) to
    /// `.notInserted(.interrupted)` so they are never typed twice, sets
    /// `origin = recovered` on every row it hands back (so `.textReady` lands them
    /// as `.recovered`, never typed), then returns what still needs text.
    ///
    /// Only what an earlier run left: a row or file from after this store opened, or
    /// one this run began (whatever its date says), belongs to a Dictation this run is
    /// recording or finishing, so it is never touched, even if Jake pressed fn before
    /// recovery ran.
    ///
    /// Idempotent: running it twice returns the same Dictations and changes nothing
    /// the second time. See RecoveryPlan.
    public func recover() async -> [UnfinishedDictation] {
        do {
            return try await read { [self] db in try recover(in: db) }
        } catch {
            log.error("Recovery failed: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// A waiting Dictation still has no text: its row is unfinished (a `.waiting` write
    /// SQLite dropped leaves it so). False once it is deleted. A read that fails says nothing, so it counts as still owed:
    /// giving up then would leave the Dictation without text until the next launch.
    public func owesText(_ id: DictationID) async -> Bool {
        do {
            let status = try await read { db in
                try db.query("SELECT status FROM dictation WHERE id = ?", [.text(id.description)]).first?.text(0)
            }
            guard let status = status.flatMap(DictationStatus.init(rawValue:)) else { return false }
            return [.recording, .transcribing, .waiting].contains(status)
        } catch {
            return true
        }
    }

    private func recover(in db: Database) throws -> [UnfinishedDictation] {
        let opened = openedAt.unixMs
        let begun = begunThisRun.withLock { $0 }
        // Every audio file an earlier run made. Its name is its Dictation's id. A file
        // whose birth date can't be read might be this run's: only an earlier row claims it.
        var created: [DictationID: Date] = [:]
        var undated: Set<DictationID> = []
        let listed = try FileManager.default
            .contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: [.creationDateKey])
        for url in listed where url.pathExtension == "caf" {
            guard let id = DictationID(column: url.deletingPathExtension().lastPathComponent),
                  !begun.contains(id) else { continue }
            if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                if date.unixMs < opened { created[id] = date }
            } else {
                undated.insert(id)
            }
        }
        let fileIDs = String(decoding: try JSONEncoder().encode((Set(created.keys).union(undated)).map(\.description)),
                             as: UTF8.self)

        // The rows recovery may act on: unfinished, half deleted, or owning a file.
        let found = try db.query("""
            SELECT id, status, audio_storage FROM dictation
            WHERE started_at < ? AND (status IN (\(HistorySchema.sqlList(\.isTerminal, is: false)))
              OR audio_storage = ? OR id IN (SELECT value FROM json_each(?)))
            ORDER BY started_at, id
            """, [.int(opened), .text(AudioStorage.deleted.rawValue), .text(fileIDs)])
        var rows: [RecoveryPlan.RowState] = []
        var owned: Set<DictationID> = []
        for row in found {
            guard let id = row.text(0).flatMap(DictationID.init(column:)), !begun.contains(id) else { continue }
            owned.insert(id)  // a row a newer build wrote still owns its file: never adopted as an orphan
            guard let status = row.text(1).flatMap(DictationStatus.init(rawValue:)),
                  let audio = row.text(2).flatMap(AudioStorage.init(rawValue:)) else { continue }
            rows.append(RecoveryPlan.RowState(id: id, status: status, audio: audio))
        }
        // Reading a header costs a file open, so only the files recovery may act on:
        // not a settled Dictation's (closed at stop), nor one whose row this build can't read.
        let parsed = Set(rows.map(\.id))
        let settled = Set(rows.filter { $0.status.isTerminal && $0.audio == .onDisk }.map(\.id))
        var files: [DictationID: RecoveryPlan.FileState] = [:]
        let candidates = Set(created.keys).union(undated.filter(parsed.contains))
        for id in candidates where !settled.contains(id) && (parsed.contains(id) || !owned.contains(id)) {
            files[id] = switch CAFFile.state(of: audioURL(for: id)) {
            case .open: .open
            case .closed: .closed
            case .empty: .empty
            case .unavailable: .unavailable
            case .unreadable: .unreadable
            }
        }

        var unfinished: [UnfinishedDictation] = []
        for action in RecoveryPlan.plan(rows: rows, files: files) {
            // One Dictation that won't recover must not strand the rest.
            do {
                if let next = try perform(action, created: created, in: db) { unfinished.append(next) }
            } catch {
                log.error("Recovery skipped a Dictation: \(String(describing: error), privacy: .private)")
            }
        }
        return unfinished
    }

    /// Applies one action. Status moves go through `apply`, so they obey the
    /// same rules as every other event.
    private func perform(_ action: RecoveryPlan.Action, created: [DictationID: Date],
                         in db: Database) throws -> UnfinishedDictation? {
        func record(_ event: DictationEvent) throws {
            guard let applied = try db.transaction({ try apply(event, in: $0) }) else { return }
            if applied.dropAudio { try dropAudio(applied.id) }
            if applied.changed { changed.yield(applied.id) }
        }

        switch action {
        case .finalize(let id):
            try CAFFile.finalize(audioURL(for: id))
        case .adoptOrphan(let id):
            // The file is all there is: the app crashed before its row was written.
            try record(.began(id, origin: .recovered, purpose: .type, at: created[id] ?? Date(), app: .unknown))
        case .deleteGarbage(let id):
            try dropAudio(id)
            changed.yield(id)
        case .dropExpiredAudio(let id), .deleteEmptyFile(let id):
            try removeAudioFile(id)
        case .discard(let id):
            try record(.discarded(id))
        case .markFailed(let id, let reason):
            try record(.failed(id, reason: reason))
        case .markInterrupted(let id):
            try record(.notInserted(id, .interrupted))
        case .transcribe(let id, let wasWaiting):
            let key = SQLValue.text(id.description)
            try db.execute("UPDATE dictation SET origin = ? WHERE id = ? AND origin != ?",
                           [.text(DictationOrigin.recovered.rawValue), key, .text(DictationOrigin.recovered.rawValue)])
            if db.changes > 0 { changed.yield(id) }
            guard let row = try db.query("SELECT \(DictationRecord.columns) FROM dictation WHERE id = ?", [key])
                .first.flatMap(DictationRecord.init(row:)) else { return nil }
            return UnfinishedDictation(id: id, audio: audioURL(for: id), purpose: row.purpose, app: row.app,
                                       wasWaiting: wasWaiting)
        }
        return nil
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
    enum FileState: Sendable, Hashable { case open, closed, empty, unavailable, unreadable }

    enum Action: Sendable, Hashable {
        case finalize(DictationID)                 // CAF still open: write its real size
        case adoptOrphan(DictationID)              // file with no row: insert row, origin recovered
        case deleteGarbage(DictationID)            // row says deleted: a crash cut a delete short
        case dropExpiredAudio(DictationID)         // retention marked it expired; the crash beat the unlink
        case deleteEmptyFile(DictationID)          // a file that never got a sample: nothing to keep
        case discard(DictationID)                  // a recording that never heard anything, like a stray tap
        case markFailed(DictationID, String)       // unfinished row, no readable audio
        case markInterrupted(DictationID)          // crashed mid-paste: notInserted(.interrupted), never retyped
        case transcribe(DictationID, wasWaiting: Bool)
    }

    /// `rows`: every row recovery may act on, in the order to transcribe them.
    /// `files`: the audio file of each of those rows, and every file with no row;
    /// an id missing here has no file.
    static func plan(rows: [RowState], files: [DictationID: FileState]) -> [Action] {
        var actions: [Action] = []
        for row in rows {
            let file = files[row.id]
            if row.audio == .deleted {
                actions.append(.deleteGarbage(row.id))
                continue
            }
            // An open that failed for now (EMFILE, EIO) says nothing about the audio: the
            // Dictation stays as it was and the next launch looks again, rather than fail one
            // that may be whole. A delete Jake made is still finished: it needs no read.
            if file == .unavailable { continue }
            if row.audio == .expired, file != nil {
                actions.append(.dropExpiredAudio(row.id))
            } else if file == .open {
                actions.append(.finalize(row.id))
            }
            switch row.status {
            case .ready:
                actions.append(.markInterrupted(row.id))
            case .recording, .transcribing, .waiting:
                // The audio file is the truth: a readable one is transcribed, even half written.
                if row.audio != .expired, file == .open || file == .closed {
                    actions.append(.transcribe(row.id, wasWaiting: row.status == .waiting))
                } else if file == .empty, row.status == .recording {
                    // No sample reached the disk: no row, as for a stray tap (DECISIONS 90).
                    actions.append(.discard(row.id))
                } else if file == .empty {
                    // Its words, if any, were only in RAM. Deleted first: a crash in between
                    // leaves no file, which fails it the same way.
                    actions.append(.deleteEmptyFile(row.id))
                    actions.append(.markFailed(row.id, "audio missing"))
                } else {
                    actions.append(.markFailed(row.id, file == nil ? "audio missing" : "audio unreadable"))
                }
            case .inserted, .notInserted, .recovered, .failed:
                break
            }
        }
        let known = Set(rows.map(\.id))
        for (id, file) in files.sorted(by: { $0.key.description < $1.key.description }) where !known.contains(id) {
            switch file {
            case .unavailable: continue  // looked at again next launch
            case .empty: actions.append(.deleteEmptyFile(id)); continue  // nothing to adopt
            case .open, .closed, .unreadable: break
            }
            if file == .open { actions.append(.finalize(id)) }
            actions.append(.adoptOrphan(id))
            actions.append(file == .unreadable ? .markFailed(id, "audio unreadable")
                                               : .transcribe(id, wasWaiting: false))
        }
        return actions
    }
}
