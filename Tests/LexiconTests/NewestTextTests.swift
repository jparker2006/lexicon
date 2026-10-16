import Foundation
import Testing
@testable import History
import AudioCapture
import LexiconDomain

// Paste-last's choice of text (#62), read through History on a throwaway data
// folder. Rows go in through History's write API, the way the Conductor writes
// them. No mic, keys, paste or network.

private let start = Date(timeIntervalSince1970: 1_800_000_000)
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let parakeet = SpeechModel.local(.parakeetUnified)
private let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                       contextBefore: "", contextAfter: "", insertedAt: start.addingTimeInterval(2))

private func makeStore() throws -> HistoryStore {
    try HistoryStore(paths: AppPaths.temporary())
}

/// A row driven to `status` as the Conductor leaves it, fn-down `offset` seconds
/// after `start`, with `cleaned` as its text. Recovered rows get the recovered
/// origin, as launch recovery gives them.
@discardableResult
private func seed(_ store: HistoryStore, at offset: Double, _ status: DictationStatus, _ cleaned: String,
                  purpose: DictationPurpose = .type) throws -> DictationID {
    let id = DictationID()
    try Data([0, 1]).write(to: store.audioURL(for: id))
    let origin: DictationOrigin = status == .recovered ? .recovered : .live
    store.record(.began(id, origin: origin, purpose: purpose, at: start.addingTimeInterval(offset), app: .unknown))
    let versions = TextVersions(model: cleaned, cleaned: cleaned)
    switch status {
    case .recording:
        break
    case .transcribing:
        store.record(.audioEnded(id, audio))
    case .waiting:
        store.record(.audioEnded(id, audio))
        store.record(.waiting(id, reason: "offline"))
    case .failed:
        store.record(.audioEnded(id, audio))
        store.record(.failed(id, reason: "silent"))
    case .ready:
        store.record(.audioEnded(id, audio))
        store.record(.textReady(id, versions, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
    case .inserted:
        store.record(.audioEnded(id, audio))
        store.record(.textReady(id, versions, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
        store.record(.delivered(id, receipt, lag: .milliseconds(420)))
    case .notInserted:
        store.record(.audioEnded(id, audio))
        store.record(.textReady(id, versions, cleanup: .rulesOnly(.off), model: parakeet, typing: true))
        store.record(.notInserted(id, .focusMoved))
    case .recovered:
        store.record(.audioEnded(id, audio))
        store.record(.textReady(id, versions, cleanup: .rulesOnly(.off), model: parakeet, typing: false))
    }
    return id
}

@Test(.timeLimit(.minutes(1))) func newestTextPicksTheNewestNotInsertedDictation() async throws {
    let store = try makeStore()
    // The newer row is written first, so the pick follows fn-down time, not the order rows were written.
    let newer = try seed(store, at: 20, .notInserted, "Newer text.")
    try seed(store, at: 10, .notInserted, "Older text.")
    await store.flush()

    let found = try #require(await store.newestText())
    #expect(found.id == newer)
    #expect(found.text == "Newer text.")
    #expect(found.newerOnItsWay == false)
}

@Test(.timeLimit(.minutes(1)), arguments: [DictationStatus.inserted, .recovered])
func newestTextPicksAnInsertedOrRecoveredDictationToo(status: DictationStatus) async throws {
    let store = try makeStore()
    let id = try seed(store, at: 10, status, "Pasted text.")
    await store.flush()

    let found = try #require(await store.newestText(), "\(status) has text and is settled")
    #expect(found.id == id)
    #expect(found.text == "Pasted text.")
    #expect(found.newerOnItsWay == false)
}

@Test(.timeLimit(.minutes(1))) func newestTextSkipsAReadyRowAndSaysTheNewestIsOnItsWay() async throws {
    let store = try makeStore()
    let older = try seed(store, at: 10, .notInserted, "Older text.")
    // Mid-paste: its text is saved, but no outcome has come back yet.
    try seed(store, at: 20, .ready, "Mid-paste text.")
    await store.flush()

    let found = try #require(await store.newestText())
    #expect(found.id == older)
    #expect(found.text == "Older text.")
    #expect(found.newerOnItsWay)
}

@Test(.timeLimit(.minutes(1)), arguments: [DictationStatus.recording, .transcribing, .waiting])
func newestTextSaysTheNewestIsOnItsWayWhileItIsWaitingOrTranscribing(newest: DictationStatus) async throws {
    let store = try makeStore()
    let older = try seed(store, at: 10, .notInserted, "Older text.")
    try seed(store, at: 20, newest, "Still coming.")
    await store.flush()

    let found = try #require(await store.newestText(), "the newest is \(newest)")
    #expect(found.id == older)
    #expect(found.text == "Older text.")
    #expect(found.newerOnItsWay)
}

@Test(.timeLimit(.minutes(1))) func newestTextSkipsFailedRespeakAndBlankRows() async throws {
    // A newer failed row has no text: it is skipped, and it is not "on its way".
    let failed = try makeStore()
    let olderFailed = try seed(failed, at: 10, .notInserted, "Older text.")
    try seed(failed, at: 20, .failed, "")
    await failed.flush()
    let afterFailed = await failed.newestText()
    #expect(afterFailed?.id == olderFailed, "a newer failed row is skipped")
    #expect(afterFailed?.newerOnItsWay == false, "a failed row is not on its way")

    // A Re-speak fixes an earlier Dictation and never pastes: settled or in flight, it is ignored.
    let respeak = try makeStore()
    let olderRespeak = try seed(respeak, at: 10, .notInserted, "Older text.")
    try seed(respeak, at: 20, .inserted, "Fixed word.", purpose: .respeak(of: olderRespeak))
    try seed(respeak, at: 30, .transcribing, "", purpose: .respeak(of: olderRespeak))
    await respeak.flush()
    let afterRespeak = await respeak.newestText()
    #expect(afterRespeak?.id == olderRespeak, "a Re-speak row is never pasted")
    #expect(afterRespeak?.newerOnItsWay == false, "an in-flight Re-speak is not on its way")

    // A newer row whose final text is only spaces is never pasted. Its status would
    // otherwise qualify, so only the blank check skips it.
    let blank = try makeStore()
    let olderBlank = try seed(blank, at: 10, .notInserted, "Older text.")
    try seed(blank, at: 20, .notInserted, "   ")
    await blank.flush()
    let afterBlank = await blank.newestText()
    #expect(afterBlank?.id == olderBlank, "a blank row is skipped")
    #expect(afterBlank?.text == "Older text.")
    #expect(afterBlank?.newerOnItsWay == false)
}

// Guard: this passes at the scaffold because its stub is nil too. It pins that
// the real pick still answers nil when nothing can be pasted: an empty History,
// and one whose only row is still waiting for a model and has no text.
@Test(.timeLimit(.minutes(1))) func newestTextIsNilWithNothingToPaste() async throws {
    let empty = try makeStore()
    await empty.flush()
    #expect(await empty.newestText() == nil)

    let waitingOnly = try makeStore()
    try seed(waitingOnly, at: 10, .waiting, "")
    await waitingOnly.flush()
    #expect(await waitingOnly.newestText() == nil)
}

// Paste-last skips a newest row whose text the paste path calls blank (`Character.isWhitespace`),
// so Unicode whitespace never hides an older Dictation from ⌃⌘V.
@Test(.timeLimit(.minutes(1)), arguments: ["\u{00A0}", "\u{2028}", "\u{3000}", "\u{0B}"])
func newestTextSkipsANewerRowWhoseTextIsOnlyWhitespace(blank: String) async throws {
    let store = try makeStore()
    let older = try seed(store, at: 10, .notInserted, "Older text.")
    try seed(store, at: 20, .notInserted, blank)
    await store.flush()

    let found = try #require(await store.newestText())
    #expect(found.id == older)
    #expect(found.text == "Older text.")
}
