import Foundation
import Testing
@testable import History
import LexiconDomain

// Audio retention through History's public API on a throwaway data folder. Audio
// files are sparse, so a "400 MB" file costs no disk and no time to write.

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let megabyte: UInt64 = 1_000_000
private let text = TextVersions(model: "ship the retention sweep", cleaned: "Ship the retention sweep.")
private let parakeet = SpeechModel.local(.parakeetUnified)

/// A Dictation started `daysAgo` before `now`, driven to `status`, with an audio file of `megabytes`.
private func dictate(_ store: HistoryStore, daysAgo: Double, status: DictationStatus = .inserted,
                     pinned: Bool = false, megabytes: UInt64 = 1, storage: AudioStorage = .onDisk) throws -> DictationID {
    let id = DictationID()
    let file = store.audioURL(for: id)
    #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
    try FileHandle(forWritingTo: file).truncate(atOffset: megabytes * megabyte)

    let origin: DictationOrigin = status == .recovered ? .recovered : .live
    store.record(.began(id, origin: origin, purpose: .type, at: now.addingTimeInterval(-daysAgo * 86_400), app: .unknown))
    let ended = AudioSummary(duration: .seconds(3), startGap: nil, deviceName: nil, storage: storage, gaps: [])
    let landed = DictationEvent.textReady(id, text, cleanup: .rulesOnly(.off), model: parakeet, typing: status == .ready)
    let events: [DictationEvent] = switch status {
    case .recording: []
    case .transcribing: [.audioEnded(id, ended)]
    case .waiting: [.audioEnded(id, ended), .waiting(id, reason: "offline")]
    case .failed: [.audioEnded(id, ended), .failed(id, reason: "silent")]
    case .ready, .recovered: [.audioEnded(id, ended), landed]
    case .notInserted: [.audioEnded(id, ended), landed, .notInserted(id, .focusMoved)]
    case .inserted: [.audioEnded(id, ended), landed,
                     .delivered(id, InsertionReceipt(appBundleID: nil, fieldFingerprint: nil, caretAfter: nil,
                                                     contextBefore: "", contextAfter: "", insertedAt: now), lag: nil)]
    }
    for event in events { store.record(event) }
    if pinned { store.record(.pinned(id, true)) }
    return id
}

private func hasAudio(_ store: HistoryStore, _ id: DictationID) async -> Bool {
    let onDisk = await store.dictation(id)?.audio == .onDisk
    let file = FileManager.default.fileExists(atPath: store.audioURL(for: id).path)
    #expect(onDisk == file, "the row and the audio folder disagree about \(id)")
    return onDisk && file
}

@Test func audioOlderThan14DaysIsRemovedAndTheTextKept() async throws {
    let store = try HistoryStore(paths: .temporary())
    let old = try dictate(store, daysAgo: 15)
    let edge = try dictate(store, daysAgo: 14)
    let recent = try dictate(store, daysAgo: 13)
    await store.flush()
    let before = try #require(await store.dictation(old))

    await store.sweepAudio(now: now)

    #expect(await !hasAudio(store, old))
    #expect(await hasAudio(store, edge))
    #expect(await hasAudio(store, recent))
    let after = try #require(await store.dictation(old))
    #expect(after.audio == .expired)
    #expect(after.status == before.status)
    #expect(after.versions == text)
    #expect(after.finalText == text.cleaned)
}

@Test func overOneGigabyteTheOldestUnpinnedNotNeededAudioGoesFirst() async throws {
    let store = try HistoryStore(paths: .temporary())
    // Neither counts against the 1 GB nor is ever removed by it.
    let pinned = try dictate(store, daysAgo: 6, pinned: true, megabytes: 900)
    let failed = try dictate(store, daysAgo: 5, status: .failed, megabytes: 900)
    let oldest = try dictate(store, daysAgo: 4, megabytes: 400)
    let middle = try dictate(store, daysAgo: 3, status: .notInserted, megabytes: 400)
    let newest = try dictate(store, daysAgo: 2, status: .recovered, megabytes: 300)
    await store.flush()

    await store.sweepAudio(now: now)

    // 1,100 MB counted: dropping the oldest 400 MB brings it to 700 MB, under the cap.
    #expect(await !hasAudio(store, oldest))
    for kept in [pinned, failed, middle, newest] { #expect(await hasAudio(store, kept)) }
    #expect(await store.dictation(oldest)?.finalText == text.cleaned)
}

@Test func audioAgedOutNoLongerCountsAgainstTheCap() async throws {
    let store = try HistoryStore(paths: .temporary())
    let old = try dictate(store, daysAgo: 15, megabytes: 600)
    let recent = try dictate(store, daysAgo: 13, megabytes: 600)
    await store.flush()

    await store.sweepAudio(now: now)

    #expect(await !hasAudio(store, old))
    #expect(await hasAudio(store, recent))
}

/// A capture that hit disk trouble keeps going in RAM and leaves a partial file behind.
@Test func aPartialFileLeftByRamOnlyCaptureAgesOutToo() async throws {
    let store = try HistoryStore(paths: .temporary())
    let id = try dictate(store, daysAgo: 15, storage: .ramOnly)
    await store.flush()

    await store.sweepAudio(now: now)

    #expect(await store.dictation(id)?.audio == .expired)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: id).path))
    #expect(await store.dictation(id)?.finalText == text.cleaned)
}

@Test func exactlyOneGigabyteIsNotOverTheCap() async throws {
    let store = try HistoryStore(paths: .temporary())
    let ids = try [600, 400].enumerated().map { try dictate(store, daysAgo: Double(5 - $0.offset), megabytes: UInt64($0.element)) }
    await store.flush()

    await store.sweepAudio(now: now)

    for id in ids { #expect(await hasAudio(store, id)) }
}

@Test(arguments: DictationStatus.allCases)
func waitingFailedAndPinnedDictationsKeepTheirAudio(status: DictationStatus) async throws {
    let store = try HistoryStore(paths: .temporary())
    let plain = try dictate(store, daysAgo: 30, status: status)
    let pinned = try dictate(store, daysAgo: 30, status: status, pinned: true)
    await store.flush()
    #expect(await store.dictation(plain)?.status == status)

    await store.sweepAudio(now: now)

    // Listed by hand, not read from `needsAudio`, so a change to that list fails here.
    let waitsForText = [DictationStatus.recording, .transcribing, .waiting, .failed].contains(status)
    #expect(await hasAudio(store, plain) == waitsForText)
    #expect(await hasAudio(store, pinned))
}

@Test func sweepingAgainChangesNothing() async throws {
    let store = try HistoryStore(paths: .temporary())
    let old = try dictate(store, daysAgo: 20)
    let recent = try dictate(store, daysAgo: 1)
    await store.flush()

    await store.sweepAudio(now: now)
    let once = [await store.dictation(old), await store.dictation(recent)]
    await store.sweepAudio(now: now)

    #expect([await store.dictation(old), await store.dictation(recent)] == once)
    #expect(await hasAudio(store, recent))
}

@Test func deletingADictationWhoseAudioAgedOutRemovesTheRow() async throws {
    let store = try HistoryStore(paths: .temporary())
    let old = try dictate(store, daysAgo: 20)
    await store.flush()
    await store.sweepAudio(now: now)

    store.record(.deleted(old))
    await store.flush()

    #expect(await store.dictation(old) == nil)
}
