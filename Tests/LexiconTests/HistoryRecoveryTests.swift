import Foundation
import Testing
@testable import History
@testable import AudioCapture
import LexiconDomain

// Launch recovery on throwaway folders. The planner is tested without disk. The
// disk tests build what a crash leaves (rows through History's write API, CAF
// files the way AudioCapture writes them), then relaunch a store and recover it.
// No mic, no app.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let text = TextVersions(model: "wire the auth callback into super base", cleaned: "Wire the auth callback into Supabase.")
private let parakeet = SpeechModel.local(.parakeetUnified)

// MARK: The planner, without disk

/// Every file state a row can have, and none at all.
private let fileStates: [RecoveryPlan.FileState?] = [nil, .open, .closed, .empty, .unavailable, .unreadable]

/// The files a planner call sees for one row: none when the row has no file.
private func fileMap(_ id: DictationID, _ state: RecoveryPlan.FileState?) -> [DictationID: RecoveryPlan.FileState] {
    state.map { [id: $0] } ?? [:]
}

/// The actions with `.markFailed`'s reason blanked: a test pins that a Dictation failed, not the wording.
private func unreasoned(_ actions: [RecoveryPlan.Action]) -> [RecoveryPlan.Action] {
    actions.map { action -> RecoveryPlan.Action in
        if case .markFailed(let id, _) = action { return .markFailed(id, "") }
        return action
    }
}

@Test func aReadyRowIsMarkedInterruptedAndNeverTranscribed() {
    let id = DictationID()
    // Crashed mid-paste: the text may or may not have landed, so it is never typed or transcribed again.
    let ready = RecoveryPlan.RowState(id: id, status: .ready, audio: .onDisk)
    #expect(RecoveryPlan.plan(rows: [ready], files: fileMap(id, nil)) == [.markInterrupted(id)])
    #expect(RecoveryPlan.plan(rows: [ready], files: fileMap(id, .closed)) == [.markInterrupted(id)])
    #expect(RecoveryPlan.plan(rows: [ready], files: fileMap(id, .unreadable)) == [.markInterrupted(id)])
    // Its mark needs no read, so a file that can't be opened for now does not hold it back a launch.
    #expect(RecoveryPlan.plan(rows: [ready], files: fileMap(id, .unavailable)) == [.markInterrupted(id)])
    // An open file still gets its size written, but the row is not transcribed.
    #expect(RecoveryPlan.plan(rows: [ready], files: fileMap(id, .open)) == [.finalize(id), .markInterrupted(id)])
}

@Test func aWaitingRowWithAClosedFileIsTranscribedAsWaiting() {
    let id = DictationID()
    let waiting = RecoveryPlan.RowState(id: id, status: .waiting, audio: .onDisk)
    #expect(RecoveryPlan.plan(rows: [waiting], files: fileMap(id, .closed)) == [.transcribe(id, wasWaiting: true)])
}

@Test func aTranscribingRowWithAClosedFileIsTranscribedAsNotWaiting() {
    let id = DictationID()
    let transcribing = RecoveryPlan.RowState(id: id, status: .transcribing, audio: .onDisk)
    #expect(RecoveryPlan.plan(rows: [transcribing], files: fileMap(id, .closed)) == [.transcribe(id, wasWaiting: false)])
}

@Test func aRecordingRowWithAnOpenFileIsFinalizedThenTranscribed() {
    // The file is the truth: a crash mid-recording keeps whatever was written.
    let id = DictationID()
    let recording = RecoveryPlan.RowState(id: id, status: .recording, audio: .onDisk)
    #expect(RecoveryPlan.plan(rows: [recording], files: fileMap(id, .open)) == [.finalize(id), .transcribe(id, wasWaiting: false)])
}

@Test func anUnfinishedRowWithNoReadableAudioFailsAndIsNotTranscribed() {
    // A file that cannot be read cannot be transcribed, so the row fails instead of going to the Conductor.
    let id = DictationID()
    for status in [DictationStatus.recording, .transcribing, .waiting] {
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .onDisk)
        #expect(unreasoned(RecoveryPlan.plan(rows: [row], files: [:])) == [.markFailed(id, "")], "\(status), no file")
        #expect(unreasoned(RecoveryPlan.plan(rows: [row], files: [id: .unreadable])) == [.markFailed(id, "")],
                "\(status), unreadable file")
    }
}

@Test func aRowMarkedDeletedIsDeleteGarbageWhetherOrNotItsFileRemains() {
    // Delete commits the mark, then unlinks the file, then drops the row. A crash in either gap
    // leaves a file or no file, and both finish the drop.
    let id = DictationID()
    for status in DictationStatus.allCases {
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .deleted)
        for state in fileStates {
            #expect(RecoveryPlan.plan(rows: [row], files: fileMap(id, state)) == [.deleteGarbage(id)],
                    "\(status), file \(String(describing: state))")
        }
    }
}

@Test func anExpiredRowWhoseFileRemainsOnlyLosesTheFile() {
    // Retention expires only rows that need no audio. It marked this one, and the crash came before
    // the unlink: finish the unlink. The text stays, and nothing is failed, transcribed or finalized.
    let id = DictationID()
    let retained = DictationStatus.allCases.filter { $0.isTerminal && !$0.needsAudio }
    for status in retained {
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .expired)
        for state in [RecoveryPlan.FileState.open, .closed, .unreadable] {
            #expect(RecoveryPlan.plan(rows: [row], files: fileMap(id, state)) == [.dropExpiredAudio(id)],
                    "\(status), file \(state)")
        }
        // A file that can't be opened for now leaves the row as it was, its unlink too, till the next launch.
        #expect(RecoveryPlan.plan(rows: [row], files: fileMap(id, .unavailable)) == [], "\(status), unavailable")
    }
}

@Test func aFileWithNoRowIsFinalizedIfOpenAndAdoptedForTranscription() {
    let id = DictationID()
    #expect(RecoveryPlan.plan(rows: [], files: [id: .open])
        == [.finalize(id), .adoptOrphan(id), .transcribe(id, wasWaiting: false)])
    #expect(RecoveryPlan.plan(rows: [], files: [id: .closed]) == [.adoptOrphan(id), .transcribe(id, wasWaiting: false)])
}

@Test func anUnreadableFileWithNoRowIsAdoptedAndFailed() {
    let id = DictationID()
    #expect(unreasoned(RecoveryPlan.plan(rows: [], files: [id: .unreadable])) == [.adoptOrphan(id), .markFailed(id, "")])
}

@Test func aSettledRowWithAClosedFilePlansNothing() {
    // Settled rows are finished. Their closed files are kept, or expired by retention, and never touched here.
    let id = DictationID()
    let settled = DictationStatus.allCases.filter(\.isTerminal)
    for status in settled {
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .onDisk)
        #expect(RecoveryPlan.plan(rows: [row], files: fileMap(id, .closed)) == [], "\(status)")
    }
}

// MARK: Empty and unavailable files (#182)

/// The rows and files as the next launch reads them once `actions` have run. `.deleteEmptyFile`
/// unlinks the file, `.discard` drops the row and its file, `.markFailed` fails the row.
private func leftBehind(by actions: [RecoveryPlan.Action], rows: [RecoveryPlan.RowState],
                        files: [DictationID: RecoveryPlan.FileState])
    -> (rows: [RecoveryPlan.RowState], files: [DictationID: RecoveryPlan.FileState]) {
    var rows = rows
    var files = files
    for action in actions {
        switch action {
        case .deleteEmptyFile(let id):
            files[id] = nil
        case .discard(let id):
            rows.removeAll { $0.id == id }
            files[id] = nil
        case .markFailed(let id, _):
            rows = rows.map { $0.id == id ? RecoveryPlan.RowState(id: id, status: .failed, audio: $0.audio) : $0 }
        default:
            break
        }
    }
    return (rows, files)
}

@Test func anEmptyAudioFileWithNoRowIsDeletedAndNotAdopted() {
    let id = DictationID()
    let files: [DictationID: RecoveryPlan.FileState] = [id: .empty]
    // Nothing was recorded, so there is no Dictation to adopt or transcribe. The file is only garbage.
    let actions = RecoveryPlan.plan(rows: [], files: files)
    #expect(actions == [.deleteEmptyFile(id)])
    let after = leftBehind(by: actions, rows: [], files: files)
    #expect(RecoveryPlan.plan(rows: after.rows, files: after.files) == [])
}

@Test func anEmptyFileUnderARecordingRowIsDiscarded() {
    let id = DictationID()
    let row = RecoveryPlan.RowState(id: id, status: .recording, audio: .onDisk)
    let files: [DictationID: RecoveryPlan.FileState] = [id: .empty]
    // The recording never heard a sample, so it is dropped like a stray tap, not failed.
    let actions = RecoveryPlan.plan(rows: [row], files: files)
    #expect(actions == [.discard(id)])
    let after = leftBehind(by: actions, rows: [row], files: files)
    #expect(RecoveryPlan.plan(rows: after.rows, files: after.files) == [])
}

@Test func anEmptyFileUnderATranscribingOrWaitingRowIsDeletedAndFailedAsAudioMissing() {
    for status in [DictationStatus.transcribing, .waiting] {
        let id = DictationID()
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .onDisk)
        let files: [DictationID: RecoveryPlan.FileState] = [id: .empty]
        // The file goes first: a crash between the two leaves an unfinished row with no file, which
        // the next launch fails the same way.
        let actions = RecoveryPlan.plan(rows: [row], files: files)
        #expect(actions == [.deleteEmptyFile(id), .markFailed(id, "audio missing")], "\(status)")
        let after = leftBehind(by: actions, rows: [row], files: files)
        #expect(RecoveryPlan.plan(rows: after.rows, files: after.files) == [], "\(status), planned again")
    }
}

@Test func anUnavailableFileIsLeftAloneForEveryUnfinishedRowAndForAnOrphan() {
    // An open that failed for a reason that may pass next launch (EMFILE, EIO, a permission): this
    // launch plans nothing for the id, so it neither fails the row nor adopts the file.
    let id = DictationID()
    for status in [DictationStatus.recording, .transcribing, .waiting] {
        let row = RecoveryPlan.RowState(id: id, status: status, audio: .onDisk)
        #expect(RecoveryPlan.plan(rows: [row], files: [id: .unavailable]) == [], "\(status)")
    }
    #expect(RecoveryPlan.plan(rows: [], files: [id: .unavailable]) == [])
}

// MARK: Relaunch on disk

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// What an earlier run left: `body` writes it through a store on a fresh folder, which is then
/// released as a quit releases it (every event applied, then the store dropped), so a relaunch can
/// take the folder's lock. `body` must not keep the store.
private func earlierRun(_ body: (HistoryStore) async throws -> Void) async throws -> AppPaths {
    let paths = AppPaths.temporary()
    let store = try HistoryStore(paths: paths)
    try await body(store)
    await store.flush()
    return paths
}

/// When an earlier run began a Dictation: well before any store these tests open.
private func earlier() -> Date { Date().addingTimeInterval(-60) }

/// Opens the store again on the same folders, as a relaunch does, once the caller has released
/// the one before it (see `earlierRun`). Recovery acts only on what is
/// older than the store's open, and both times are rounded to whole milliseconds, so waiting for
/// the next one keeps every file the test wrote strictly before it.
private func relaunch(_ paths: AppPaths) async throws -> HistoryStore {
    let written = (Date().timeIntervalSince1970 * 1_000).rounded()
    await until { (Date().timeIntervalSince1970 * 1_000).rounded() > written }
    return try await onceFolderIsFree { try HistoryStore(paths: paths) }
}

/// A closed CAF the way a finished recording leaves it: every sample in, the data size written.
private func writeClosedCAF(_ samples: [Int16], at url: URL) async throws {
    let wav = try writeWAV(samples, rate: 16_000, in: try scratchDirectory())
    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: url)
    let ended = try #require(await capture.signals.inputEnded())
    _ = await capture.stop(.released(at: ended))
    await recorder.settle()
    #expect(CAFFile.state(of: url) == .closed)
}

/// A CAF the way a crash leaves it: the data size is still -1, as a writer that never closed it leaves it.
private func writeOpenCAF(_ samples: [Int16], at url: URL) async throws {
    try await writeClosedCAF(samples, at: url)
    var bytes = try Data(contentsOf: url)
    // The data chunk's tag is followed by its 8-byte size. The first "data" in the file is that chunk's
    // header, since the format chunk before it has no such text. The state check below confirms it.
    let tag = try #require(bytes.firstRange(of: Data("data".utf8)))
    bytes.replaceSubrange(tag.upperBound..<tag.upperBound + 8, with: repeatElement(UInt8(0xFF), count: 8))
    try bytes.write(to: url)
    #expect(CAFFile.state(of: url) == .open)
}

/// Every dictation row in full, and the audio folder's file names. Equal before and after a
/// second recovery means it changed nothing.
private func snapshot(_ store: HistoryStore) async throws -> [String] {
    let rows = try await store.read { db in try db.query("SELECT * FROM dictation ORDER BY id").map { "\($0)" } }
    let files = try FileManager.default.contentsOfDirectory(atPath: store.audioFolder.path(percentEncoded: false))
    return rows + files.sorted()
}

func statusReason(_ store: HistoryStore, _ id: DictationID) async throws -> String? {
    try await store.read { db in
        try db.query("SELECT status_reason FROM dictation WHERE id = ?", [.text(id.description)]).first?.text(0)
    }
}

@Test func aDictationCutShortMidRecordingIsFinalizedAndHandedBack() async throws {
    let id = DictationID()
    let samples = syntheticSamples(count: 32_000)  // 2 s, then the crash
    let paths = try await earlierRun { store in
        store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        try await writeOpenCAF(samples, at: store.audioURL(for: id))
    }

    let relaunched = try await relaunch(paths)
    let unfinished = await relaunched.recover()

    let item = try #require(unfinished.first)
    #expect(unfinished.map(\.id) == [id])
    #expect(item.audio == relaunched.audioURL(for: id))
    #expect(item.wasWaiting == false)
    #expect(item.app == app)
    #expect(CAFFile.state(of: item.audio) == .closed)
    #expect(try CAFFile.read(item.audio).samples == samples)
    let row = try #require(await relaunched.dictation(id))
    #expect(row.origin == .recovered)  // recovered text is never typed (#4)
    #expect(row.status == .recording)  // the Conductor's transcription moves it on
}

@Test func recoveringTwiceReturnsTheSameDictationsAndChangesNothingTheSecondTime() async throws {
    let samples = syntheticSamples(count: 16_000)
    // One Dictation of each kind recovery acts on, and a file with no row.
    let ready = DictationID()
    let waiting = DictationID()
    let cut = DictationID()
    let deleted = DictationID()
    let noFile = DictationID()
    let orphan = DictationID()
    let paths = try await earlierRun { store in
        store.record(.began(ready, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(ready, audio))
        store.record(.textReady(ready, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
        store.record(.began(waiting, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(waiting, audio))
        store.record(.waiting(waiting, reason: "offline"))
        store.record(.began(cut, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.began(deleted, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(deleted, audio))
        store.record(.failed(deleted, reason: "silent"))
        store.record(.began(noFile, origin: .live, purpose: .type, at: earlier(), app: app))
        try await writeClosedCAF(samples, at: store.audioURL(for: ready))
        try await writeClosedCAF(samples, at: store.audioURL(for: waiting))
        try await writeOpenCAF(samples, at: store.audioURL(for: cut))
        try await writeClosedCAF(samples, at: store.audioURL(for: deleted))
        try await writeClosedCAF(samples, at: store.audioURL(for: orphan))
        // The first half of a delete: marked, and the file is still there.
        try await store.read { db in
            try db.execute("UPDATE dictation SET audio_storage = 'deleted' WHERE id = ?", [.text(deleted.description)])
        }
    }

    let first: [UnfinishedDictation]
    let once: [String]
    do {
        let relaunched = try await relaunch(paths)
        first = await relaunched.recover()
        #expect(Set(first.map(\.id)) == [waiting, cut, orphan])
        once = try await snapshot(relaunched)

        // Again on the same store: the same Dictations, and nothing written.
        let second = await relaunched.recover()
        #expect(second.count == first.count)
        #expect(Set(second.map(\.id)) == Set(first.map(\.id)))
        #expect(try await snapshot(relaunched) == once)

        await relaunched.flush()
    }

    // And on the next launch.
    let next = try await relaunch(paths)
    let third = await next.recover()
    #expect(Set(third.map(\.id)) == Set(first.map(\.id)))
    #expect(try await snapshot(next) == once)
}

@Test func aRowLeftReadyBecomesNotInsertedInterrupted() async throws {
    let id = DictationID()
    let paths = try await earlierRun { store in
        store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(id, audio))
        store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
        try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
    }

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)  // never handed back to be typed or transcribed

    let row = try #require(await relaunched.dictation(id))
    #expect(row.status == .notInserted)
    #expect(try await statusReason(relaunched, id) == "interrupted")
    #expect(row.finalText == text.cleaned)  // kept, so paste-last still reaches it
}

@Test(arguments: [true, false])
func aDeleteCutShortAfterItsMarkIsFinishedOnRelaunch(fileSurvived: Bool) async throws {
    let id = DictationID()
    let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                   contextBefore: "the words around", contextAfter: "the paste", insertedAt: earlier())
    let paths = try await earlierRun { store in
        store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(id, audio))
        store.record(.attempted(id, AttemptRecord(model: parakeet, result: .won, text: text.model, latency: nil, error: nil)))
        store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
        store.record(.delivered(id, receipt, lag: .milliseconds(420)))
        try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
        await store.flush()
        // Delete's first half, committed on its own. The crash came before the unlink (file kept) or
        // after it (file already gone), and before the row was dropped either way.
        try await store.read { db in _ = try db.transaction { try store.apply(.deleted(id), in: $0) } }
        if !fileSurvived { try FileManager.default.removeItem(at: store.audioURL(for: id)) }
        // Already no text anywhere: not in the row, not in the rows that hang off it.
        let leftover = try await store.read { db in
            try ["attempt", "fix", "insertion"].map { try db.query("SELECT 1 FROM \($0) WHERE dictation_id = ?", [.text(id.description)]).count }
        }
        #expect(leftover == [0, 0, 0])
        #expect(await store.dictation(id)?.finalText == nil)
    }

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)
    #expect(await relaunched.dictation(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: relaunched.audioURL(for: id).path(percentEncoded: false)))
}

@Test func anAudioFileWithNoRowBecomesARecoveredRowThatIsStillRecording() async throws {
    let id = DictationID()
    // A crash before the row was written: the file is all there is.
    let paths = try await earlierRun { store in
        try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
    }

    let relaunched = try await relaunch(paths)
    let unfinished = await relaunched.recover()

    #expect(unfinished.map(\.id) == [id])
    #expect(unfinished.first?.wasWaiting == false)
    let row = try #require(await relaunched.dictation(id))
    #expect(row.origin == .recovered)
    #expect(row.status == .recording)  // it waits for the Conductor's transcription
}

@Test(arguments: [DictationStatus.recording, .transcribing, .waiting])
func anUnfinishedRowWithNoAudioFileFailsAndIsNotHandedBack(status: DictationStatus) async throws {
    let id = DictationID()
    // No file is written: the crash came before any audio reached disk, or the file was lost.
    let paths = try await earlierRun { store in
        store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        if status != .recording { store.record(.audioEnded(id, audio)) }
        if status == .waiting { store.record(.waiting(id, reason: "offline")) }
    }

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)
    #expect(await relaunched.dictation(id)?.status == .failed)
}

@Test func aDictationStillRecordingInThisRunIsLeftAlone() async throws {
    let (store, _) = try makeStore()
    let id = DictationID()
    // Begun in this run, so recovery's on the same store must not finish it.
    store.record(.began(id, origin: .live, purpose: .type, at: Date(), app: app))
    try await writeOpenCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
    await store.flush()

    #expect(await store.recover().isEmpty)
    #expect(CAFFile.state(of: store.audioURL(for: id)) == .open)
    #expect(await store.dictation(id)?.status == .recording)
}

// MARK: CAF files with no sample yet (#182)

/// The shapes a CAF file takes before any sample reaches disk.
private enum EmptyCAFShape: CaseIterable {
    /// A file created and never written.
    case zeroBytes
    /// Cut before the data chunk's tag: the header and format chunk, no data chunk yet.
    case headerOnly
    /// The data chunk's tag, its size set to -1 as a crash leaves it, and its edit count, with no sample.
    case dataChunkWithNoSample
    /// A closed CAF cut after its edit count: the header still claims samples the disk no longer has.
    case closedCutToNoSample
    /// A closed CAF whose header says its data chunk holds no sample (size 4: the edit count only).
    case closedSaysNoSample
    /// Cut inside the 8-byte file header: the writer died writing its first bytes.
    case partFileHeader
}

/// Writes an empty CAF of `shape` at `url`, cut from a real closed CAF the Recorder wrote, so the
/// header and format chunk are the ones AudioCapture writes.
private func writeEmptyCAF(_ shape: EmptyCAFShape, at url: URL) async throws {
    guard shape != .zeroBytes else { return try Data().write(to: url) }
    guard shape != .partFileHeader else { return try Data("caff".utf8).write(to: url) }
    let closed = try scratchDirectory().appending(path: "closed.caf")
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: closed)
    let bytes = try Data(contentsOf: closed)
    // The format chunk before the data chunk has no "data" text, so the first one is the tag.
    let tag = try #require(bytes.firstRange(of: Data("data".utf8)))
    if shape == .headerOnly {
        try Data(bytes[..<tag.lowerBound]).write(to: url)
    } else {
        // The tag, the 8-byte size and the 4-byte edit count, and no sample after them.
        var cut = Data(bytes[..<(tag.upperBound + 12)])
        let size: UInt64? = switch shape {
        case .dataChunkWithNoSample: .max  // -1, as a crash leaves it
        case .closedSaysNoSample: 4
        default: nil
        }
        if let size {
            cut.replaceSubrange(tag.upperBound..<(tag.upperBound + 8), with: withUnsafeBytes(of: size.bigEndian, Array.init))
        }
        try cut.write(to: url)
    }
}

@Test(arguments: EmptyCAFShape.allCases)
private func anEmptyCAFShapeIsReadAsEmpty(shape: EmptyCAFShape) async throws {
    let url = try scratchDirectory().appending(path: "\(shape).caf")
    try await writeEmptyCAF(shape, at: url)
    #expect(CAFFile.state(of: url) == .empty, "\(shape)")
}

@Test func aClosedOpenOrTextFileIsReadAsClosedOpenOrUnreadable() async throws {
    // The states an empty file must not be mistaken for: a finished recording, a crashed one, and a file that is not audio.
    let folder = try scratchDirectory()
    let closed = folder.appending(path: "closed.caf")
    let open = folder.appending(path: "open.caf")
    let prose = folder.appending(path: "notes.txt")
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: closed)
    try await writeOpenCAF(syntheticSamples(count: 16_000), at: open)
    try Data("not audio, just words\n".utf8).write(to: prose)
    #expect(CAFFile.state(of: closed) == .closed)
    #expect(CAFFile.state(of: open) == .open)
    #expect(CAFFile.state(of: prose) == .unreadable)
    // Shorter than a CAF's file header and not the start of one: not audio, so kept, never deleted as empty.
    let stub = folder.appending(path: "stub.caf")
    try Data("hello".utf8).write(to: stub)
    #expect(CAFFile.state(of: stub) == .unreadable)
}

@Test func finalizeSaysWhatItDid() async throws {
    // The close path logs this, so "repaired" is said only when a size was written.
    let folder = try scratchDirectory()
    let open = folder.appending(path: "open.caf")
    try await writeOpenCAF(syntheticSamples(count: 16_000), at: open)
    #expect(try CAFFile.finalize(open) == .wroteSize)
    #expect(try CAFFile.finalize(open) == .wasWhole)
    let empty = folder.appending(path: "empty.caf")
    try await writeEmptyCAF(.dataChunkWithNoSample, at: empty)
    #expect(try CAFFile.finalize(empty) == .noSample)
}

@Test(arguments: EmptyCAFShape.allCases)
private func finalizingAnEmptyCAFReturnsAndLeavesItsBytesAlone(shape: EmptyCAFShape) async throws {
    let url = try scratchDirectory().appending(path: "\(shape).caf")
    try await writeEmptyCAF(shape, at: url)
    let before = try Data(contentsOf: url)
    // A throw fails whatever row holds the file, and a rewrite changes the bytes a later launch reads.
    var thrown: (any Error)?
    do {
        try CAFFile.finalize(url)
    } catch {
        thrown = error
    }
    #expect(thrown == nil, "\(shape): finalize threw \(String(describing: thrown))")
    #expect(try Data(contentsOf: url) == before, "\(shape): finalize changed the file")
}

@Test func theWriterClosedBeforeAnySampleLeavesTheSameEmptyFileACrashDoes() throws {
    // AudioFile keeps a CAF with no packet as it created it: closing the writer (what CaptureCore
    // does when the first write fails) leaves the bytes a crash before the first write leaves.
    let url = try scratchDirectory().appending(path: "never-written.caf")
    let created: Data
    do {
        // Closed when it goes out of scope, by its deinit, as a dropped writer is.
        let writer = try CAFWriter(creating: url)
        #expect(CAFFile.state(of: url) == .empty)
        created = try Data(contentsOf: url)
        withExtendedLifetime(writer) {}
    }
    #expect(CAFFile.state(of: url) == .empty)
    #expect(try Data(contentsOf: url) == created)
}

@Test func aCAFWhoseChunkRunsPastItsEndIsUnreadableNotEmpty() async throws {
    // A damaged chunk size that jumps over the data chunk must not make a file with audio look
    // empty: an empty file is deleted, and an unreadable one is kept.
    let url = try scratchDirectory().appending(path: "damaged.caf")
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: url)
    var bytes = try Data(contentsOf: url)
    // The first chunk after the 8-byte file header is the format chunk; its size is bytes 12..<20.
    let huge = UInt64(bytes.count * 4)
    bytes.replaceSubrange(12..<20, with: withUnsafeBytes(of: huge.bigEndian, Array.init))
    try bytes.write(to: url)
    #expect(CAFFile.state(of: url) == .unreadable)
}

@Test func aCAFRefusedForGoodOrMissingIsUnreadable() async throws {
    let folder = try scratchDirectory()
    let url = folder.appending(path: "closed.caf")
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: url)
    let path = url.path(percentEncoded: false)
    // Restored even when an expectation fails, so no test leaves an unreadable temp file behind.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    // Mode zero: a permission error, which no later launch gets past by itself.
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
    #expect(CAFFile.state(of: url) == .unreadable)
    #expect(CAFFile.state(of: folder.appending(path: "missing.caf")) == .unreadable)
}

@Test func aCAFThatCannotBeOpenedForWantOfDescriptorsIsUnavailable() async throws {
    let url = try scratchDirectory().appending(path: "closed.caf")
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: url)
    // In a child process, so using up its descriptors touches no other test.
    await #expect(processExitsWith: .success) { [path = url.path(percentEncoded: false) as String] in
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        limit.rlim_cur = 64
        setrlimit(RLIMIT_NOFILE, &limit)
        while open("/dev/null", O_RDONLY) >= 0 {}  // every descriptor taken: the next open fails with EMFILE
        exit(CAFFile.state(of: URL(filePath: path)) == .unavailable ? 0 : 1)
    }
}

@Test func anEmptyAudioFileFromAnEarlierRunIsDeletedDiscardedOrFailedAndRecoveryChangesNothingAfter() async throws {
    let orphan = DictationID()      // a file with no row: the app died before its row was written
    let recording = DictationID()   // a recording whose file never got a sample
    let waiting = DictationID()     // a Dictation waiting for an engine, its file never got a sample
    let paths = try await earlierRun { store in
        try await writeEmptyCAF(.zeroBytes, at: store.audioURL(for: orphan))
        store.record(.began(recording, origin: .live, purpose: .type, at: earlier(), app: app))
        try await writeEmptyCAF(.dataChunkWithNoSample, at: store.audioURL(for: recording))
        store.record(.began(waiting, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(waiting, audio))
        store.record(.waiting(waiting, reason: "offline"))
        try await writeEmptyCAF(.headerOnly, at: store.audioURL(for: waiting))
    }

    let relaunched = try await relaunch(paths)
    // An empty file has no text to transcribe, so nothing is handed back.
    #expect(await relaunched.recover().isEmpty)

    // The orphan: neither its file nor a row is left.
    #expect(!FileManager.default.fileExists(atPath: relaunched.audioURL(for: orphan).path(percentEncoded: false)))
    #expect(await relaunched.dictation(orphan) == nil)

    // The recording that never heard anything: no row and no file, so no failed row in History.
    #expect(!FileManager.default.fileExists(atPath: relaunched.audioURL(for: recording).path(percentEncoded: false)))
    #expect(await relaunched.dictation(recording) == nil)

    // The waiting Dictation: failed for its missing audio, and its empty file is gone.
    #expect(await relaunched.dictation(waiting)?.status == .failed)
    #expect(try await statusReason(relaunched, waiting) == "audio missing")
    #expect(!FileManager.default.fileExists(atPath: relaunched.audioURL(for: waiting).path(percentEncoded: false)))

    // Recovering again on the same store hands back nothing and changes nothing.
    let once = try await snapshot(relaunched)
    #expect(await relaunched.recover().isEmpty)
    #expect(try await snapshot(relaunched) == once)
}

@Test func aWaitingDictationWhoseFileIsRefusedForGoodFailsAsUnreadable() async throws {
    // A permission error does not pass by itself, so the Dictation is settled, not held in flight
    // on every launch, where History would refuse to delete it.
    let id = DictationID()
    let paths = try await earlierRun { store in
        store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        store.record(.audioEnded(id, audio))
        store.record(.waiting(id, reason: "offline"))
        try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
    }
    let path = HistoryStore.audioURL(for: id, in: paths).path(percentEncoded: false)
    // Restored even when an expectation fails, so no test leaves an unreadable temp file behind.
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)
    #expect(await relaunched.dictation(id)?.status == .failed)
    #expect(try await statusReason(relaunched, id) == "audio unreadable")
}

// MARK: This run's Dictations, and one store per folder (#182)

@Test func anHourOldRowAndFileBegunThisRunAreLeftAloneUntilARelaunch() async throws {
    let inRun = DictationID()
    let noFile = DictationID()
    // Both dates are an hour back, and older than the store's open: the wall clock alone would call them
    // an earlier run's, as a clock stepped back at launch does.
    let anHourAgo = Date().addingTimeInterval(-3_600)
    let paths = AppPaths.temporary()
    do {
        let store = try HistoryStore(paths: paths)
        #expect(anHourAgo < store.openedAt)
        store.record(.began(inRun, origin: .live, purpose: .type, at: anHourAgo, app: app))
        try await writeOpenCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: inRun))
        try FileManager.default.setAttributes([.creationDate: anHourAgo],
                                              ofItemAtPath: store.audioURL(for: inRun).path(percentEncoded: false))
        // Begun this run with no audio file yet: recovery must not fail it as a file that went missing.
        store.record(.began(noFile, origin: .live, purpose: .type, at: anHourAgo, app: app))
        await store.flush()

        // Same store, same run: nothing is handed back, and neither row nor file is finished.
        #expect(await store.recover().isEmpty)
        #expect(CAFFile.state(of: store.audioURL(for: inRun)) == .open)
        #expect(await store.dictation(inRun)?.status == .recording)
        #expect(await store.dictation(noFile)?.status == .recording)
        await store.flush()
    }

    // The same row and file, now an earlier run's: recovery hands the first back and finishes its file.
    let relaunched = try await relaunch(paths)
    let unfinished = await relaunched.recover()
    #expect(unfinished.map(\.id) == [inRun])
    #expect(CAFFile.state(of: relaunched.audioURL(for: inRun)) == .closed)
    #expect(await relaunched.dictation(noFile)?.status == .failed)
}

@Test func aSecondStoreOnALiveFolderThrowsAndLeavesTheDataAloneThenOpensAfterRelease() async throws {
    let id = DictationID()
    let paths = AppPaths.temporary()
    let before: [String]
    do {
        // A finished recording: a row and its audio file, both on disk before the attempt.
        let first = try HistoryStore(paths: paths)
        first.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
        first.record(.audioEnded(id, audio))
        try await writeClosedCAF(syntheticSamples(count: 16_000), at: first.audioURL(for: id))
        before = try await snapshot(first)
        try #require(await first.dictation(id)?.status == .transcribing)

        // `first` is still alive here: it holds the folder's lock, and it is used again below.
        #expect(throws: (any Error).self) { try HistoryStore(paths: paths) }

        // The failed open touched neither the row nor the file.
        #expect(try await snapshot(first) == before)
        await first.flush()
    }

    // Released: a new store opens on the same folder and reads what the first one left.
    let second = try await onceFolderIsFree { try HistoryStore(paths: paths) }
    #expect(try await snapshot(second) == before)
}

@Test func twoTemporaryFoldersEachOpenAStoreSideBySide() async throws {
    let id = DictationID()
    // Each folder is its own: a live store on one must not block a store on the other, or write into it.
    let one = try HistoryStore(paths: AppPaths.temporary())
    let two = try HistoryStore(paths: AppPaths.temporary())
    one.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
    await one.flush()
    await two.flush()
    #expect(await one.dictation(id)?.status == .recording)
    #expect(await two.dictation(id) == nil)
}
