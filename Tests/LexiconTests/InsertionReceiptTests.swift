import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// Every insert leaves a receipt in History (app, field fingerprint, caret,
// short context): the late-text rule and Re-speak find the text again by it.
// Headless: the real Conductor on a WAV, a destination that answers like a paste.

private let typed = "Wire the auth callback into Supabase."

/// Answers every insert with `delivery`.
private actor Answering: TextDestination {
    struct Target: Sendable {}
    let delivery: Delivery
    init(_ delivery: Delivery) { self.delivery = delivery }
    func context() -> AppContext { AppContext(bundleID: "com.example.editor", appName: nil, windowTitle: nil, workingDirectory: nil) }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(context()) } }
    func target() -> Target? { Target() }
    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery { delivery }
}

private func dictate(into destination: Answering) async throws -> (DictationResult, HistoryStore) {
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: ScriptedTranscriber(text: typed)), cleanup: Cleanup(),
        lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    return (result, history)
}

@Test func aPastedDictationKeepsItsReceiptInHistory() async throws {
    let receipt = InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "9f3a#77", caretAfter: 120,
                                   contextBefore: "Please ", contextAfter: " today.",
                                   insertedAt: Date(timeIntervalSince1970: 1_791_000_000))
    let (result, history) = try await dictate(into: Answering(.inserted(receipt)))

    #expect(result.status == .inserted)
    #expect(await history.dictation(result.id)?.status == .inserted)
    #expect(await history.receipt(for: result.id) == receipt)
}

@Test func aPasteNobodyReadLeavesNoReceiptAndWaitsForPasteLast() async throws {
    let (result, history) = try await dictate(into: Answering(.notInserted(.pasteFailed)))

    #expect(result.status == .notInserted)
    let row = try #require(await history.dictation(result.id))
    #expect(row.status == .notInserted)
    #expect(row.finalText != nil)  // still there for paste-last
    #expect(await history.receipt(for: result.id) == nil)
}
