import Foundation
import Testing
@testable import AudioCapture
@testable import History
@testable import LexiconCore
import AppText
import Cleanup
import LexiconDomain
import Transcription
import WordStore

// A live Re-speak's text is queued for History before its replace types it, so
// its row reads `ready` while the words are being pasted, and `inserted` after
// (review.md, Never lose a Dictation). A refused replace ends `notInserted`, leaves
// the field alone, and is never offered to paste-last. Headless: the real Conductor
// on a synthesized WAV per Dictation, a local engine that hears one text per clip,
// and one simulated field whose `replace` reads the Re-speak's History row before
// it answers. No mic, keys or network.

/// Hears one text per clip, in the order the clips were dictated, and the last
/// text again after that. Copied from RespeakSelectionTests, where it is private.
private actor HearingInOrder: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var texts: [String]

    init(_ texts: [String]) { self.texts = texts }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { clip in await self.transcribe(clip, terms: terms, priority: priority) }
    }

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) -> String {
        texts.count > 1 ? texts.removeFirst() : texts[0]
    }
}

/// One field, as HeadlessDestination is. Jake's selection is set with `select`
/// before fn-down and captured at `target()`. `refusal` nil: `replace` pastes;
/// otherwise it refuses with that reason. Each `replace` first reads, from
/// History, the status of every Re-speak row as it stands then.
private actor RespeakFieldDestination: TextDestination {
    struct Target: Sendable {
        let selection: FieldSelection?
    }

    private static let fingerprint = "respeak-field"

    private let history: HistoryStore
    private let refusal: ReplaceRefusal?
    private var pendingSelection: TextSpan?
    private var fieldGone = false
    private(set) var fieldText = ""
    /// The status of the Re-speak's row at each `replace`, in the order they ran.
    private(set) var respeakStatusesAtReplace: [DictationStatus] = []

    init(history: HistoryStore, refusal: ReplaceRefusal? = nil) {
        self.history = history
        self.refusal = refusal
    }

    /// Tests: Jake selects `span` of the field before the next fn-down.
    func select(_ span: TextSpan) { pendingSelection = span }

    /// Tests: from now on no field can take text, so every `target()` is nil.
    func loseField() { fieldGone = true }

    func context() -> AppContext { .unknown }

    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }

    func target() -> Target? {
        let selection = pendingSelection.flatMap { span in
            HeadlessDestination.text(in: fieldText, at: span).map { FieldSelection(span: span, text: $0) }
        }
        pendingSelection = nil
        guard !fieldGone else { return nil }
        return Target(selection: selection)
    }

    // `async` like the requirement, as HeadlessDestination's read is.
    func read(at target: Target) async -> FieldText? {
        FieldText(text: fieldText, selection: target.selection, bundleID: nil, fieldFingerprint: Self.fingerprint)
    }

    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        fieldText += text
        return .inserted(receipt(caretAfter: fieldText.utf16.count))
    }

    func replace(_ span: TextSpan, expected: String, with text: String, at target: Target) async -> ReplaceOutcome {
        respeakStatusesAtReplace += await respeakRowStatuses()
        if let refusal { return .refused(refusal) }
        guard HeadlessDestination.text(in: fieldText, at: span) == expected else { return .refused(.textChanged) }
        let start = fieldText.utf16.index(fieldText.utf16.startIndex, offsetBy: span.location)
        let end = fieldText.utf16.index(start, offsetBy: span.length)
        fieldText.replaceSubrange(start..<end, with: text)
        return .replaced(receipt(caretAfter: span.location + text.utf16.count))
    }

    /// Every Re-speak row's status, read from History after the writes queued before this call.
    private func respeakRowStatuses() async -> [DictationStatus] {
        let rows = try? await history.read { db in
            try db.query("SELECT \(DictationRecord.columns) FROM dictation").compactMap(DictationRecord.init(row:))
        }
        return (rows ?? []).filter { row in
            if case .respeak = row.purpose { true } else { false }
        }.map(\.status)
    }

    private func receipt(caretAfter: Int) -> InsertionReceipt {
        InsertionReceipt(appBundleID: nil, fieldFingerprint: Self.fingerprint, caretAfter: caretAfter,
                         contextBefore: "", contextAfter: "", insertedAt: Date())
    }
}

/// A Conductor over `destination` and `history`, hearing `texts` one per clip.
private func makeConductor(_ destination: RespeakFieldDestination, history: HistoryStore, paths: AppPaths,
                           hearing texts: String...) throws -> Conductor<RespeakFieldDestination> {
    Conductor(
        recorder: Recorder(), speech: SpeechEngine(local: HearingInOrder(texts), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
}

/// One second of audio, dictated with `purpose`.
private func dictate(_ conductor: Conductor<RespeakFieldDestination>,
                     purpose: DictationPurpose = .type) async throws -> DictationResult {
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
    return await conductor.dictate(file: wav, pace: .asFastAsPossible, purpose: purpose)
}

/// One second of audio, dictated live as a Re-speak of `fixing`. `dictate(file:)`
/// is origin `.file`, and `handle(.dictationBegan)` only ever starts a `.type`
/// Dictation, so this starts the Conductor's own run with origin `.live`, as
/// `handle` does. The WAV stands in for the mic: its end is the fn-up, which is
/// the one thing that ends this run, and it is where the target is captured.
private func liveRespeak(_ conductor: Conductor<RespeakFieldDestination>, of fixing: DictationID,
                         id: DictationID) async throws -> DictationResult {
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: try scratchDirectory())
    let (ends, open) = AsyncStream<RunEnd>.makeStream()
    defer { open.finish() }  // a finished stream reads as "stop now"
    let start = RunStart(id: id, input: .file(wav, pace: .asFastAsPossible), preferences: .defaults,
                         origin: .live, purpose: .respeak(of: fixing), began: .now())
    return await conductor.run(start, ends: ends, hold: LatencyHold(reason: "Re-speak \(id)"))
}

/// The events of one Dictation, up to its `finished`. Subscribe before it runs:
/// the stream keeps the newest events, and `finished` is the last one emitted.
private func emitted(_ stream: AsyncStream<ConductorEvent>, until id: DictationID) async -> [ConductorEvent] {
    var seen: [ConductorEvent] = []
    for await event in stream {
        seen.append(event)
        if case .finished(let finished, _) = event, finished == id { break }
    }
    return seen
}

/// The notices among `events`, in order.
private func notices(_ events: [ConductorEvent]) -> [Notice] {
    events.compactMap { event -> Notice? in
        guard case .notice(let notice) = event else { return nil }
        return notice
    }
}

@Test(.timeLimit(.minutes(1)))
func aLiveRespeakReadsReadyInHistoryWhileItsWordsArePastedAndInsertedAfter() async throws {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let destination = RespeakFieldDestination(history: history)
    let conductor = try makeConductor(destination, history: history, paths: paths,
                                      hearing: "the cat saw the cat", "dog")
    let first = try await dictate(conductor)
    await history.flush()
    #expect(first.status == .inserted)
    #expect(await destination.fieldText == "the cat saw the cat")

    await destination.select(TextSpan(location: 16, length: 3))  // the second "cat"
    let respeak = try await dictate(conductor, purpose: .respeak(of: first.id))
    await history.flush()

    // Queued for History before the paste: the Re-speak's row reads ready while its replace runs.
    let atReplace = await destination.respeakStatusesAtReplace
    #expect(atReplace == [.ready], "the Re-speak's row while its replace ran: \(atReplace)")
    #expect(await history.dictation(respeak.id)?.status == .inserted)
    #expect(await destination.fieldText == "the cat saw the dog")
}

@Test(.timeLimit(.minutes(1)))
func aRefusedLiveRespeakEndsNotInsertedLeavesTheFieldAndIsNeverOfferedToPasteLast() async throws {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let destination = RespeakFieldDestination(history: history, refusal: .focusMoved)
    let conductor = try makeConductor(destination, history: history, paths: paths,
                                      hearing: "the cat saw the cat", "dog")
    let first = try await dictate(conductor)
    await history.flush()
    #expect(first.status == .inserted)
    let before = await destination.fieldText

    await destination.select(TextSpan(location: 16, length: 3))  // the second "cat"
    let events = await conductor.events()
    let respeak = try await dictate(conductor, purpose: .respeak(of: first.id))
    await history.flush()

    #expect(await history.dictation(respeak.id)?.status == .notInserted)
    #expect(await destination.fieldText == before)
    let seen = await emitted(events, until: respeak.id)
    #expect(notices(seen).contains(.fixNotLanded(.movedOn)))
    // A Re-speak's words are a correction, never offered to paste-last.
    #expect(!notices(seen).contains(.readyToPaste(respeak.id)))
}

@Test(.timeLimit(.minutes(1)))
func aLiveRespeakWithNoFieldAtFnUpSaysTheFixDidNotLandAndIsNeverOfferedToPasteLast() async throws {
    let paths = AppPaths.temporary()
    let history = try HistoryStore(paths: paths)
    let destination = RespeakFieldDestination(history: history)
    let conductor = try makeConductor(destination, history: history, paths: paths,
                                      hearing: "the cat saw the cat", "dog")
    let first = try await dictate(conductor)
    await history.flush()
    #expect(first.status == .inserted)
    let before = await destination.fieldText

    await destination.loseField()  // no field can take text at fn-up
    let events = await conductor.events()
    let respeak = DictationID()
    _ = try await liveRespeak(conductor, of: first.id, id: respeak)
    await history.flush()

    #expect(await destination.fieldText == before)
    let seen = await emitted(events, until: respeak)
    // The fix that did not land is said, never silent: the indicator reads it as "No text field to fix".
    #expect(notices(seen).contains(.fixNotLanded(.noField)))
    // A Re-speak's words are a correction, never offered to paste-last.
    #expect(!notices(seen).contains(.readyToPaste(respeak)))
}
