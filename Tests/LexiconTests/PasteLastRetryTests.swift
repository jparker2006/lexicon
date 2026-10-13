import Foundation
import Testing
@testable import LexiconCore
import AudioCapture
import History
import LexiconDomain

// A Retry after ⌃⌘V: what Retry reports is what History holds. A Retry of a
// recovered row paste-last already inserted replaces its text and stays inserted
// (DECISIONS item 57, built by #213), so "Retried" is true, never a write History
// refused. The rule both use is `DictationStatus.landed`: a previous status that
// has text keeps its place. Retry still types nothing.

// MARK: The rule, without disk

// Every status a Retry can start from: any row with text, and a failed row (a Retry
// that gets text from it). A nil previous is a first landing with no stored row to
// move, so there is no transition to check for it.
@Test func historyAdmitsEveryStatusThatLandedGivesAHistoryOnlyText() {
    let previous = DictationStatus.allCases.filter { $0.hasText || $0 == .failed }
    for origin in DictationOrigin.allCases {
        for status in previous {
            let landed = DictationStatus.landed(.historyOnly, origin: origin, previous: status)
            #expect(status.canMove(to: landed), "\(origin), previous \(status), lands as \(landed)")
        }
    }
}

// MARK: The Retry, headless

private func wav() throws -> URL {
    try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
}

@Test(.timeLimit(.minutes(1))) func aRetryOfARecoveredDictationPasteLastInsertedWritesWhatItReports() async throws {
    // A recovered Dictation with text, as launch recovery leaves one: never typed,
    // its audio on disk, its text kept.
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: ScriptedTranscriber(text: "second try"), clock: TestClock())
    let id = DictationID()
    let recorder = Recorder()
    let capture = try await recorder.start(.file(try wav(), pace: .asFastAsPossible),
                                           writingTo: system.history.audioURL(for: id))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()
    system.history.record(.began(id, origin: .recovered, purpose: .type, at: Date(), app: .unknown))
    system.history.record(.audioEnded(id, take.summary))
    system.history.record(.textReady(id, TextVersions(model: "first try", cleaned: "First try."),
                                     cleanup: .rulesOnly(.off), model: .local(.parakeetUnified), typing: false))
    // Paste-last inserted it: the same record the paste path writes after a paste lands.
    let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "f1", caretAfter: 37,
                                   contextBefore: "the words around", contextAfter: "the paste", insertedAt: Date())
    system.history.record(.delivered(id, receipt, lag: nil))
    await system.history.flush()
    try #require(await system.history.dictation(id)?.status == .inserted)

    let retried = await system.conductor.retry(id, with: nil)
    await system.history.flush()

    // What Retry reports is what History holds: a Retry that writes says inserted,
    // and the row carries the text it wrote.
    #expect(retried.status == .inserted)
    let row = try #require(await system.history.dictation(id))
    #expect(row.status == .inserted)
    if let versions = retried.versions {
        #expect(row.finalText == versions.cleaned)
    }
}
