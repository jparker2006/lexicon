import Foundation
import Testing
@testable import History
import AudioCapture
import LexiconDomain

// History through its write API on a throwaway data folder: no mic, no app.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let text = TextVersions(model: "wire the auth callback into super base", cleaned: "Wire the auth callback into Supabase.")
private let parakeet = SpeechModel.local(.parakeetUnified)
private let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                       contextBefore: "", contextAfter: "", insertedAt: start.addingTimeInterval(2))

private func makeStore() throws -> (HistoryStore, AppPaths) {
    let paths = AppPaths.temporary()
    return (try HistoryStore(paths: paths), paths)
}

/// A row with an audio file, as AudioCapture leaves it at fn-down.
private func begin(_ store: HistoryStore, origin: DictationOrigin = .live,
                   purpose: DictationPurpose = .type) throws -> DictationID {
    let id = DictationID()
    try Data([0, 1]).write(to: store.audioURL(for: id))
    store.record(.began(id, origin: origin, purpose: purpose, at: start, app: app))
    return id
}

/// The events that drive a fresh row to `status`.
private func path(to status: DictationStatus, _ id: DictationID) -> [DictationEvent] {
    let transcribing: [DictationEvent] = [.audioEnded(id, audio)]
    let ready = transcribing + [.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true)]
    switch status {
    case .recording: return []
    case .transcribing: return transcribing
    case .waiting: return transcribing + [.waiting(id, reason: "offline")]
    case .failed: return transcribing + [.failed(id, reason: "silent")]
    case .ready: return ready
    case .inserted: return ready + [.delivered(id, receipt, lag: .milliseconds(420))]
    case .notInserted: return ready + [.notInserted(id, .focusMoved)]
    case .recovered: return transcribing + [.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: false)]
    }
}

/// Every status-moving event, and the status it asks for from a live row.
private func movingEvents(_ id: DictationID, stored: DictationStatus) -> [(DictationEvent, DictationStatus)] {
    [
        (.audioEnded(id, audio), .transcribing),
        (.waiting(id, reason: "offline"), .waiting),
        (.failed(id, reason: "silent"), .failed),
        (.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true), .ready),
        (.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: false),
         DictationStatus.landed(.historyOnly, origin: .live, previous: stored)),
        (.delivered(id, receipt, lag: .milliseconds(420)), .inserted),
        (.notInserted(id, .typedSince), .notInserted),
    ]
}

/// Every stored column of every row about `id`, in all four tables.
private func snapshot(_ store: HistoryStore, _ id: DictationID) async throws -> [String] {
    try await store.read { db in
        try ["dictation WHERE id", "attempt WHERE dictation_id", "fix WHERE dictation_id", "insertion WHERE dictation_id"]
            .flatMap { try db.query("SELECT * FROM \($0) = ? ORDER BY rowid", [.text(id.description)]) }
            .map { "\($0)" }
    }
}

private func indexSQL(_ store: HistoryStore) async throws -> [String] {
    try await store.read { db in
        try db.query("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'dictation_unfinished'").compactMap { $0.text(0) }
    }
}

private func origin(for status: DictationStatus) -> DictationOrigin { status == .recovered ? .recovered : .live }

@Test func aDictationIsRecordedThroughToInserted() async throws {
    let (store, _) = try makeStore()
    let id = try begin(store)
    for event in path(to: .inserted, id) { store.record(event) }
    await store.flush()

    let row = try #require(await store.dictation(id))
    #expect(row.status == .inserted)
    #expect(row.startedAt == start)
    #expect(row.origin == .live)
    #expect(row.purpose == .type)
    #expect(row.versions == text)
    #expect(row.finalText == text.cleaned)
    #expect(row.cleanup == .rulesOnly(.off))
    #expect(row.model == parakeet)
    #expect(row.lag == .milliseconds(420))
    #expect(row.app.bundleID == app.bundleID)
    #expect(row.audio == .onDisk)
    #expect(row.pinned == false)
    #expect(await store.receipt(for: id) == receipt)
}

@Test(arguments: DictationStatus.allCases)
func aStoredRowMovesOnlyWhereTheRulesAllow(stored: DictationStatus) async throws {
    let (store, _) = try makeStore()
    for index in movingEvents(DictationID(), stored: stored).indices {
        let id = try begin(store, origin: origin(for: stored))
        for event in path(to: stored, id) { store.record(event) }
        await store.flush()
        #expect(await store.dictation(id)?.status == stored)

        let (event, wanted) = movingEvents(id, stored: stored)[index]
        store.record(event)
        await store.flush()
        let expected = stored.canMove(to: wanted) ? wanted : stored
        #expect(await store.dictation(id)?.status == expected, "\(stored) + event for \(wanted)")
    }
}

@Test(arguments: DictationStatus.allCases)
func replayingAnyEventTwiceChangesNothing(stored: DictationStatus) async throws {
    let (store, _) = try makeStore()
    let id = try begin(store, origin: origin(for: stored))
    for event in path(to: stored, id) { store.record(event) }
    let fix = Fix(dictation: id, kind: .respeak, source: .respeak, before: "Supabase", after: "Supabase Auth",
                  verdict: .proposed, at: start)
    let others: [DictationEvent] = [
        .began(id, origin: .live, purpose: .type, at: start.addingTimeInterval(9), app: .unknown),
        .attempted(id, AttemptRecord(model: parakeet, result: .won, text: text.model, latency: .milliseconds(90), error: nil)),
        .fixRecorded(fix),
        .fixVerdict(fix.id, .confirmed),
        .pinned(id, true),
        .discarded(id),
        .deleted(id),
    ]
    for event in movingEvents(id, stored: stored).map(\.0) + others {
        store.record(event)
        await store.flush()
        let once = try await snapshot(store, id)
        store.record(event)
        await store.flush()
        #expect(try await snapshot(store, id) == once, "replayed \(event) from \(stored)")
    }
}

@Test func anEventForAnUnknownDictationChangesNothing() async throws {
    let (store, _) = try makeStore()
    let ghost = DictationID()
    for event in movingEvents(ghost, stored: .recording).map(\.0) + [.pinned(ghost, true), .deleted(ghost), .discarded(ghost)] {
        store.record(event)
    }
    store.record(.attempted(ghost, AttemptRecord(model: parakeet, result: .lost, text: nil, latency: nil, error: nil)))
    store.record(.fixRecorded(Fix(dictation: ghost, kind: .hand, source: .axWatch, before: "a", after: "b",
                                  verdict: .proposed, at: start)))
    await store.flush()
    #expect(await store.dictation(ghost) == nil)
    #expect(try await snapshot(store, ghost).isEmpty)
}

@Test(arguments: DictationStatus.allCases)
func deleteIsRefusedWhileInFlight(stored: DictationStatus) async throws {
    let (store, _) = try makeStore()
    let id = try begin(store, origin: origin(for: stored))
    for event in path(to: stored, id) { store.record(event) }
    store.record(.deleted(id))
    await store.flush()

    let file = store.audioURL(for: id).path(percentEncoded: false)
    if stored.isInFlight {
        #expect(await store.dictation(id)?.status == stored)
        #expect(FileManager.default.fileExists(atPath: file))
    } else {
        #expect(await store.dictation(id) == nil)
        #expect(await store.receipt(for: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: file))
    }
}

@Test func aStrayTapLeavesNothingButOnlyWhileRecording() async throws {
    let (store, _) = try makeStore()
    let tap = try begin(store)
    store.record(.discarded(tap))
    let kept = try begin(store)
    store.record(.audioEnded(kept, audio))
    store.record(.discarded(kept))
    await store.flush()

    #expect(await store.dictation(tap) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: tap).path(percentEncoded: false)))
    #expect(await store.dictation(kept)?.status == .transcribing)
    #expect(FileManager.default.fileExists(atPath: store.audioURL(for: kept).path(percentEncoded: false)))
}

@Test func finalTextIsCleanedTextPlusFixes() async throws {
    let (store, _) = try makeStore()
    let id = try begin(store)
    for event in path(to: .inserted, id) { store.record(event) }
    let fix = Fix(dictation: id, kind: .respeak, source: .respeak, before: "auth", after: "OAuth",
                  verdict: .proposed, at: start.addingTimeInterval(5))
    store.record(.fixRecorded(fix))
    await store.flush()
    #expect(await store.dictation(id)?.finalText == "Wire the OAuth callback into Supabase.")

    // A replayed `.textReady` (manual Retry, same text) recomputes; it never erases the Fix.
    store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: false))
    await store.flush()
    #expect(await store.dictation(id)?.finalText == "Wire the OAuth callback into Supabase.")
    #expect(await store.dictation(id)?.status == .inserted)

    store.record(.fixVerdict(fix.id, .rejected))
    await store.flush()
    #expect(await store.dictation(id)?.finalText == text.cleaned)
    #expect(await store.dictation(id)?.versions == text)
}

@Test func reSpeakAudioRemembersWhatItFixes() async throws {
    let (store, _) = try makeStore()
    let original = try begin(store)
    let respeak = try begin(store, purpose: .respeak(of: original))
    // The original was deleted before the Re-speak started: the row is still saved.
    let orphan = try begin(store, purpose: .respeak(of: DictationID()))
    await store.flush()
    #expect(await store.dictation(respeak)?.purpose == .respeak(of: original))
    #expect(await store.dictation(orphan)?.status == .recording)
}

@Test func pinningAndCleanupOutcomeRoundTrip() async throws {
    let (store, _) = try makeStore()
    let id = try begin(store)
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, text, cleanup: .rulesOnly(.rejected(.numberMismatch)), model: .cloud(.museVoice), typing: true))
    store.record(.pinned(id, true))
    await store.flush()
    let row = try #require(await store.dictation(id))
    #expect(row.cleanup == .rulesOnly(.rejected(.numberMismatch)))
    #expect(row.model == .cloud(.museVoice))
    #expect(row.pinned)
}

@Test(.timeLimit(.minutes(1))) func changesNamesEveryRowThatMoved() async throws {
    let (store, _) = try makeStore()
    let a = try begin(store)
    let b = try begin(store)
    store.record(.audioEnded(a, audio))
    store.record(.audioEnded(a, audio))  // replay: nothing changed, no notice
    for event in path(to: .inserted, b) { store.record(event) }
    store.record(.delivered(b, receipt, lag: .milliseconds(420)))  // replay: no notice
    await store.flush()
    var seen: [DictationID] = []
    for await changed in store.changes {
        seen.append(changed)
        if seen.count == 6 { break }
    }
    #expect(seen == [a, b, a, b, b, b])
}

@Test func derivedIndexesAreRebuiltWhenTheirSQLChanges() async throws {
    let paths: AppPaths
    weak var released: HistoryStore?
    do {
        let (store, folder) = try makeStore()
        paths = folder
        released = store
        #expect(try await indexSQL(store) == HistorySchema.derivedIndexes)

        // An index an older build generated from a different status list.
        try await store.read { db in
            try db.execute("DROP INDEX dictation_unfinished")
            try db.execute("CREATE INDEX dictation_unfinished ON dictation(status) WHERE status IN ('recording')")
        }
        #expect(try await indexSQL(store) != HistorySchema.derivedIndexes)
        await store.flush()
    }
    // Released as a quit does, so the reopen can take the folder's lock.
    await until { released == nil }  // its deinit frees the folder's lock: the signal, not a clock
    let reopened = try HistoryStore(paths: paths)
    #expect(try await indexSQL(reopened) == HistorySchema.derivedIndexes)
}

@Test(.timeLimit(.minutes(1))) func enqueuingAnEventNeverWaitsOnTheWriter() async throws {
    let (store, _) = try makeStore()
    let ids = try (0..<200).map { _ in try begin(store) }
    await store.flush()

    // Hold the writer queue: if `record` waited on SQLite, this test would hang
    // until its time limit failed it. How long a record takes is not tested here:
    // that is machine speed.
    let release = DispatchSemaphore(value: 0)
    var held: Task<Void, any Error>!
    await withCheckedContinuation { started in
        held = Task { try await store.read { _ in started.resume(); release.wait() } }  // timing-ok: the held writer under test; released below
    }

    for _ in 0..<5 {
        for id in ids { store.record(.pinned(id, true)) }
    }
    release.signal()
    try await held.value
    await store.flush()

    #expect(await store.dictation(ids[0])?.pinned == true)
}

@Test func recoveredTextIsNeverTypedEvenIfACallerAsks() async throws {
    let (store, _) = try makeStore()
    let id = try begin(store, origin: .recovered)
    store.record(.audioEnded(id, audio))
    store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    await store.flush()
    #expect(await store.dictation(id)?.status == .recovered)
}

/// A Dictation inserted with a real CAF of `samples`, written the way capture writes it.
private func captured(_ store: HistoryStore, _ samples: [Int16], storage: AudioStorage = .onDisk) async throws -> DictationID {
    let id = DictationID()
    let wav = try writeWAV(samples, rate: 16_000, in: try scratchDirectory())
    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: store.audioURL(for: id))
    let ended = try #require(await capture.signals.inputEnded())
    _ = await capture.stop(.released(at: ended))
    await recorder.settle()
    store.record(.began(id, origin: .live, purpose: .type, at: start, app: app))
    store.record(.audioEnded(id, AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic", storage: storage, gaps: [])))
    store.record(.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    store.record(.delivered(id, receipt, lag: .milliseconds(420)))
    await store.flush()
    return id
}

// MARK: - Retry audio

@Test func aDictationsWholeAudioComesBackForRetry() async throws {
    let (store, _) = try makeStore()
    let source = syntheticSamples(count: 16_000)
    let id = try await captured(store, source)

    #expect(try #require(await store.clip(id)).samples == source)
}

@Test func aClipIsGoneOnceRetentionTakesTheAudio() async throws {
    let (store, _) = try makeStore()
    let id = try await captured(store, syntheticSamples(count: 16_000))
    await store.sweepAudio(now: start.addingTimeInterval(15 * 86_400))

    #expect(await store.dictation(id)?.audio == .expired)
    #expect(await store.clip(id) == nil)
}

@Test func aDeletedDictationHasNoClip() async throws {
    let (store, _) = try makeStore()
    let id = try await captured(store, syntheticSamples(count: 16_000))
    store.record(.deleted(id))
    await store.flush()

    #expect(await store.clip(id) == nil)
}

@Test func aRamOnlyCapturesPartialFileIsNoClip() async throws {
    // The file reads fine; it is still only part of the Dictation, so Retry must not use it.
    let (store, _) = try makeStore()
    let id = try await captured(store, syntheticSamples(count: 16_000), storage: .ramOnly)
    #expect((try? CAFFile.read(store.audioURL(for: id))) != nil)

    #expect(await store.clip(id) == nil)
}

@Test func anUnknownDictationHasNoClip() async throws {
    let (store, _) = try makeStore()
    #expect(await store.clip(DictationID()) == nil)
}

// MARK: - Pinning

@Test func aPinNeedsTheWholeAudioOnDisk() async throws {
    // The Test set needs the audio: a Dictation whose audio aged out, or whose capture is partial, cannot be pinned.
    let (store, _) = try makeStore()
    let aged = try begin(store)
    for event in path(to: .inserted, aged) { store.record(event) }
    await store.sweepAudio(now: start.addingTimeInterval(15 * 86_400))
    let partial = try begin(store)
    store.record(.audioEnded(partial, AudioSummary(duration: .milliseconds(1_200), startGap: nil, deviceName: "Mic",
                                                   storage: .ramOnly, gaps: [])))
    store.record(.pinned(aged, true))
    store.record(.pinned(partial, true))
    await store.flush()

    #expect(await store.dictation(aged)?.audio == .expired)
    #expect(await store.dictation(aged)?.pinned == false)
    #expect(await store.dictation(partial)?.pinned == false)
}

@Test func aPinNeedsTheAudioFileNotJustTheColumn() async throws {
    // A crash can lose a file whose row still says onDisk; recovery marks it failed, audio missing.
    let (store, _) = try makeStore()
    let id = try begin(store)
    try FileManager.default.removeItem(at: store.audioURL(for: id))
    store.record(.failed(id, reason: "audio missing"))
    store.record(.pinned(id, true))
    await store.flush()

    #expect(await store.dictation(id)?.audio == .onDisk)
    #expect(await store.dictation(id)?.pinned == false)
}

@Test func aPinComesOff() async throws {
    let (store, _) = try makeStore()
    let id = try begin(store)
    for event in path(to: .inserted, id) { store.record(event) }
    store.record(.pinned(id, true))
    await store.flush()
    #expect(await store.dictation(id)?.pinned == true)

    store.record(.pinned(id, false))
    await store.flush()
    #expect(await store.dictation(id)?.pinned == false)
}
