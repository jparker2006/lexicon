import Foundation
import Testing
@testable import History
import AudioCapture
import LexiconDomain

// `receipt(for:)` through History's write API on a throwaway data folder. A Dictation
// that never inserted has no receipt (nil). A read that fails throws: it is not
// the same answer as "never inserted". No mic, no app, no sleeps.

private let app = AppContext(bundleID: "com.example.editor", appName: "Editor", windowTitle: nil, workingDirectory: nil)
private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let text = TextVersions(model: "wire the auth callback into super base", cleaned: "Wire the auth callback into Supabase.")
private let parakeet = SpeechModel.local(.parakeetUnified)
private let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                       contextBefore: "", contextAfter: "", insertedAt: start.addingTimeInterval(2))

private func makeStore() throws -> HistoryStore {
    try HistoryStore(paths: AppPaths.temporary())
}

/// A row with an audio file, as AudioCapture leaves it at fn-down.
private func begin(_ store: HistoryStore, origin: DictationOrigin = .live) throws -> DictationID {
    let id = DictationID()
    try Data([0, 1]).write(to: store.audioURL(for: id))
    store.record(.began(id, origin: origin, purpose: .type, at: start, app: app))
    return id
}

private func origin(for status: DictationStatus) -> DictationOrigin { status == .recovered ? .recovered : .live }

/// The events that drive a fresh row to `status` (the same paths HistoryStoreTests drives).
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

@Test(arguments: DictationStatus.allCases.filter { $0 != .inserted })
func aDictationNeverInsertedHasNoReceipt(status: DictationStatus) async throws {
    let store = try makeStore()
    let id = try begin(store, origin: origin(for: status))
    for event in path(to: status, id) { store.record(event) }
    await store.flush()

    #expect(try await store.receipt(for: id) == nil, "\(status)")
}

@Test func aDictationNoHistoryHasNoReceipt() async throws {
    let store = try makeStore()
    #expect(try await store.receipt(for: DictationID()) == nil)
}

@Test(arguments: [DictationStatus.inserted, .notInserted])
func aFailedReceiptReadThrowsInsteadOfSayingNeverInserted(status: DictationStatus) async throws {
    let store = try makeStore()
    let id = try begin(store)
    for event in path(to: status, id) { store.record(event) }
    await store.flush()

    // The insertion table is gone, so the SELECT in receipt(for:) fails with an SQLite error.
    try await store.read { try $0.execute("DROP TABLE insertion") }
    // Setup check, not the finding: the same SELECT, unswallowed, really errors now.
    await #expect(throws: (any Error).self) { try await store.read { _ = try $0.query("SELECT 1 FROM insertion") } }

    await #expect(throws: (any Error).self) { try await store.receipt(for: id) }
}

@Test func anInsertedDictationStillReturnsItsReceipt() async throws {
    let store = try makeStore()
    let id = try begin(store)
    for event in path(to: .inserted, id) { store.record(event) }
    await store.flush()

    #expect(try await store.receipt(for: id) == receipt)
}
