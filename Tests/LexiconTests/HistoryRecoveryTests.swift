import Foundation
import Testing
@testable import History
import AudioCapture
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
private let fileStates: [RecoveryPlan.FileState?] = [nil, .open, .closed, .unreadable]

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

// MARK: Relaunch on disk

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// When an earlier run began a Dictation: well before any store these tests open.
private func earlier() -> Date { Date().addingTimeInterval(-60) }

/// Opens the store again on the same folders, as a relaunch does. Recovery acts only on what is
/// older than the store's open, and both times are rounded to whole milliseconds, so waiting for
/// the next one keeps every file the test wrote strictly before it.
private func relaunch(_ paths: AppPaths) async throws -> HistoryStore {
    let written = (Date().timeIntervalSince1970 * 1_000).rounded()
    await until { (Date().timeIntervalSince1970 * 1_000).rounded() > written }
    return try HistoryStore(paths: paths)
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
    let (store, paths) = try makeStore()
    let id = DictationID()
    let samples = syntheticSamples(count: 32_000)  // 2 s, then the crash
    store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
    try await writeOpenCAF(samples, at: store.audioURL(for: id))
    await store.flush()

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
    let (store, paths) = try makeStore()
    let samples = syntheticSamples(count: 16_000)
    // One Dictation of each kind recovery acts on, and a file with no row.
    let ready = DictationID()
    store.record(.began(ready, origin: .live, purpose: .type, at: earlier(), app: app))
    store.record(.audioEnded(ready, audio))
    store.record(.textReady(ready, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    let waiting = DictationID()
    store.record(.began(waiting, origin: .live, purpose: .type, at: earlier(), app: app))
    store.record(.audioEnded(waiting, audio))
    store.record(.waiting(waiting, reason: "offline"))
    let cut = DictationID()
    store.record(.began(cut, origin: .live, purpose: .type, at: earlier(), app: app))
    let deleted = DictationID()
    store.record(.began(deleted, origin: .live, purpose: .type, at: earlier(), app: app))
    store.record(.audioEnded(deleted, audio))
    store.record(.failed(deleted, reason: "silent"))
    let noFile = DictationID()
    store.record(.began(noFile, origin: .live, purpose: .type, at: earlier(), app: app))
    let orphan = DictationID()
    try await writeClosedCAF(samples, at: store.audioURL(for: ready))
    try await writeClosedCAF(samples, at: store.audioURL(for: waiting))
    try await writeOpenCAF(samples, at: store.audioURL(for: cut))
    try await writeClosedCAF(samples, at: store.audioURL(for: deleted))
    try await writeClosedCAF(samples, at: store.audioURL(for: orphan))
    // The first half of a delete: marked, and the file is still there.
    try await store.read { db in
        try db.execute("UPDATE dictation SET audio_storage = 'deleted' WHERE id = ?", [.text(deleted.description)])
    }
    await store.flush()

    let relaunched = try await relaunch(paths)
    let first = await relaunched.recover()
    #expect(Set(first.map(\.id)) == [waiting, cut, orphan])
    let once = try await snapshot(relaunched)

    // Again on the same store: the same Dictations, and nothing written.
    let second = await relaunched.recover()
    #expect(second.count == first.count)
    #expect(Set(second.map(\.id)) == Set(first.map(\.id)))
    #expect(try await snapshot(relaunched) == once)

    // And on the next launch.
    let next = try await relaunch(paths)
    let third = await next.recover()
    #expect(Set(third.map(\.id)) == Set(first.map(\.id)))
    #expect(try await snapshot(next) == once)
}

@Test func aRowLeftReadyBecomesNotInsertedInterrupted() async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))
    await store.flush()

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)  // never handed back to be typed or transcribed

    let row = try #require(await relaunched.dictation(id))
    #expect(row.status == .notInserted)
    #expect(try await statusReason(relaunched, id) == "interrupted")
    #expect(row.finalText == text.cleaned)  // kept, so paste-last still reaches it
}

@Test(arguments: [true, false])
func aDeleteCutShortAfterItsMarkIsFinishedOnRelaunch(fileSurvived: Bool) async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                   contextBefore: "the words around", contextAfter: "the paste", insertedAt: earlier())
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

    let relaunched = try await relaunch(paths)
    #expect(await relaunched.recover().isEmpty)
    #expect(await relaunched.dictation(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path(percentEncoded: false)))
}

@Test func anAudioFileWithNoRowBecomesARecoveredRowThatIsStillRecording() async throws {
    let (store, paths) = try makeStore()
    let id = DictationID()
    // A crash before the row was written: the file is all there is.
    try await writeClosedCAF(syntheticSamples(count: 16_000), at: store.audioURL(for: id))

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
    let (store, paths) = try makeStore()
    let id = DictationID()
    // No file is written: the crash came before any audio reached disk, or the file was lost.
    store.record(.began(id, origin: .live, purpose: .type, at: earlier(), app: app))
    if status != .recording { store.record(.audioEnded(id, audio)) }
    if status == .waiting { store.record(.waiting(id, reason: "offline")) }
    await store.flush()

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
