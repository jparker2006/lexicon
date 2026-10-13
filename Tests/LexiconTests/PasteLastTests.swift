import Foundation
import Testing
@testable import AudioCapture
@testable import KeyInput
@testable import LexiconCore
import AppText
import Cleanup
import History
import LexiconDomain
import LexiconUI
import Transcription
import WordStore

// ⌃⌘V pastes the final text of the newest Dictation that has text (#62), headless:
// the real Conductor on a WAV (or a live Dictation on a fake mic), and a destination
// that records every paste-last it is asked for, in order. No mic, keys, paste or network.

private let spokenText = "Um, so can you, uh, refactor the useAuth hook so it it doesn't re-render on every keystroke?"
private let cleanedText = "Can you refactor the useAuth hook so it doesn't re-render on every keystroke?"
private let audio = AudioSummary(duration: .milliseconds(1_200), startGap: .milliseconds(40), deviceName: "Mic",
                                 storage: .onDisk, gaps: [])
private let parakeet = SpeechModel.local(.parakeetUnified)

/// One paste-last the destination was asked for: the text and the Dictation it came from.
private struct PasteCall: Equatable, Sendable {
    let text: String
    let id: DictationID
}

/// Answers a live `insert` with `answer`, answers every paste-last with an inserted receipt,
/// and records each paste-last in the order it was asked for.
private actor PastingDestination: TextDestination {
    struct Target: Sendable {}
    let answer: Delivery
    private(set) var pasteCalls: [PasteCall] = []

    init(answer: Delivery) { self.answer = answer }

    func context() -> AppContext { .unknown }
    func appChanges() -> AsyncStream<AppContext> { AsyncStream { $0.yield(.unknown) } }
    func target() -> Target? { Target() }
    func insert(_ text: String, for id: DictationID, at target: Target) -> Delivery { answer }
    func pasteLast(_ text: String, for id: DictationID, at target: Target) -> Delivery {
        pasteCalls.append(PasteCall(text: text, id: id))
        return .inserted(InsertionReceipt(appBundleID: "com.example.editor", fieldFingerprint: "paste",
                                          caretAfter: text.utf16.count, contextBefore: "", contextAfter: "",
                                          insertedAt: Date()))
    }
}

/// Answers with `text` at once, unless `holdAnswers()` was called: then every answer waits for `release()`.
/// It holds a Dictation in transcribing for as long as the test needs, on an explicit signal, not a clock.
private actor GatedTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private let text: String
    private var holding = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(text: String) { self.text = text }

    var isResident: Bool { true }
    func load() {}
    func unload() {}
    nonisolated func session(terms: [Term], priority: LocalPriority) -> any LocalSession {
        WholeClipSession { _ in await self.answer() }
    }

    /// Every answer from now on waits for `release()`.
    func holdAnswers() { holding = true }

    /// Lets every held answer through, and every later one at once.
    func release() {
        holding = false
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    private func answer() async -> String {
        if holding { await withCheckedContinuation { waiters.append($0) } }
        return text
    }
}

/// A Conductor on `destination`, with History on `paths`. Nothing else is wired: no keyboard, fixes or Jev.
private func makeConductor(_ destination: PastingDestination, recorder: Recorder = Recorder(),
                           transcriber: any LocalTranscriber = ScriptedTranscriber(text: spokenText),
                           paths: AppPaths = .temporary()) throws -> (Conductor<PastingDestination>, HistoryStore) {
    let history = try HistoryStore(paths: paths)
    let conductor = Conductor(
        recorder: recorder, speech: SpeechEngine(local: transcriber, clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
        preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
        keyboard: nil, fixes: nil, jev: nil)
    return (conductor, history)
}

/// Every event up to and including the first `.finished`. A run that types or waits always ends in one.
private func eventsUntilFinished(_ events: inout AsyncStream<ConductorEvent>.Iterator) async -> [ConductorEvent] {
    var seen: [ConductorEvent] = []
    while let event = await events.next() {
        seen.append(event)
        if case .finished = event { break }
    }
    return seen
}

/// What one paste-last emitted: every event up to its `.pasted`, or its `.notice`, which is what a
/// paste-last that pastes nothing says. `pasteLast()` has returned by the time this reads, so what it
/// emitted is already buffered. A paste that emits neither runs into the test's time limit.
private func eventsOfPasteLast(_ events: inout AsyncStream<ConductorEvent>.Iterator) async -> [ConductorEvent] {
    var seen: [ConductorEvent] = []
    while let event = await events.next() {
        seen.append(event)
        if case .pasted = event { break }
        if case .notice = event { break }
    }
    return seen
}

/// The next Dictation to start transcribing that is not `done`. Its `.transcribing` event comes after its
/// row is recorded as transcribing, so a History read that follows it sees that status.
private func nextTranscribing(after done: DictationID,
                              _ events: inout AsyncStream<ConductorEvent>.Iterator) async -> DictationID? {
    while let event = await events.next() {
        if case .transcribing(let who) = event, who != done { return who }
    }
    return nil
}

/// The pill's state once `events` have been applied in order.
private func pillAfter(_ events: [ConductorEvent]) -> IndicatorState {
    var follower = IndicatorFollower()
    for event in events { _ = follower.apply(event) }
    return follower.state
}

// MARK: Copied from FnDictationTests and LateTextNoticeTests (private there): the fake clock for a live Dictation.

/// fn-down is two seconds before now and every later fn event is placed after it, so all of them
/// are in the past when the Conductor reads them, as real ones are.
private let fnZero = HostTime(nanoseconds: HostTime.now().nanoseconds - 2_000_000_000)

/// `milliseconds` after fn-down.
private func fnAt(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: fnZero.nanoseconds + UInt64(milliseconds) * 1_000_000)
}

// MARK: Paste-last

@Test(.timeLimit(.minutes(1)))
func pasteLastPastesTheNewestNotInsertedDictationAndMarksItInserted() async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let destination = PastingDestination(answer: .notInserted(.focusMoved))
    let (conductor, history) = try makeConductor(destination)
    var events = await conductor.events().makeAsyncIterator()

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    #expect(result.status == .notInserted)
    _ = await eventsUntilFinished(&events)

    await conductor.pasteLast()
    await history.flush()
    let pasted = await eventsOfPasteLast(&events)

    #expect(await destination.pasteCalls == [PasteCall(text: cleanedText, id: result.id)])
    let row = try #require(await history.dictation(result.id))
    #expect(row.status == .inserted)
    #expect(pasted.contains(where: { event in
        if case .pasted(let who, let newerOnItsWay) = event { who == result.id && !newerOnItsWay } else { false }
    }))
}

@Test(.timeLimit(.minutes(1)))
func pasteLastTwicePastesTheSameTextTwice() async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let destination = PastingDestination(answer: .notInserted(.focusMoved))
    let (conductor, history) = try makeConductor(destination)

    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    #expect(result.status == .notInserted)

    await conductor.pasteLast()
    await history.flush()
    await conductor.pasteLast()
    await history.flush()

    let call = PasteCall(text: cleanedText, id: result.id)
    #expect(await destination.pasteCalls == [call, call])
}

@Test(.timeLimit(.minutes(1)))
func aSuccessfulPasteLastClearsTheNotTypedPill() async throws {
    // A live Dictation on a fake mic, so fn's confirmation comes from the Conductor, as in the app.
    // A file Dictation is never confirmed, so the pill would never follow it.
    let recorder = Recorder(hardware: FakeMic().hardware)
    let destination = PastingDestination(answer: .notInserted(.focusMoved))
    let (conductor, history) = try makeConductor(destination, recorder: recorder)
    var events = await conductor.events().makeAsyncIterator()
    let id = DictationID()

    for command: KeyCommand in [.dictationBegan(id, at: fnAt(0)), .dictationConfirmed(id, .hold),
                                .dictationStopped(id, at: fnAt(600))] {
        await conductor.handle(command)
    }
    let dictated = await eventsUntilFinished(&events)
    await recorder.settle()
    await history.flush()
    #expect(pillAfter(dictated) == .pasteLast)  // "Not typed" is up before the paste

    await conductor.pasteLast()
    await history.flush()
    let pasted = await eventsOfPasteLast(&events)

    #expect(pillAfter(dictated + pasted) == .landed)
}

@Test(.timeLimit(.minutes(1)))
func withTheNewestStillOnItsWayPasteLastPastesTheOneBeforeAndSaysSo() async throws {
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let transcriber = GatedTranscriber(text: spokenText)
    let destination = PastingDestination(answer: .notInserted(.focusMoved))
    let (conductor, history) = try makeConductor(destination, transcriber: transcriber)
    var events = await conductor.events().makeAsyncIterator()

    let older = await conductor.dictate(file: wav, pace: .asFastAsPossible)
    await history.flush()
    #expect(older.status == .notInserted)

    // The newer Dictation is held in transcribing: its answer waits for the gate.
    await transcriber.holdAnswers()
    let newer = Task { await conductor.dictate(file: wav, pace: .asFastAsPossible) }
    guard let newerID = await nextTranscribing(after: older.id, &events) else {
        await transcriber.release()
        _ = await newer.value
        Issue.record("the newer Dictation never started transcribing")
        return
    }
    await history.flush()
    #expect(await history.dictation(newerID)?.status == .transcribing)

    await conductor.pasteLast()
    await history.flush()
    let pasted = await eventsOfPasteLast(&events)

    // The one before the newest pastes, and the event says the newest is on its way.
    #expect(await destination.pasteCalls == [PasteCall(text: cleanedText, id: older.id)])
    #expect(pasted.contains(where: { event in
        if case .pasted(let who, let newerOnItsWay) = event { who == older.id && newerOnItsWay } else { false }
    }))

    await transcriber.release()
    _ = await newer.value
}

@Test(.timeLimit(.minutes(1)))
func pasteLastPastesARecoveredDictation() async throws {
    let destination = PastingDestination(answer: .notInserted(.focusMoved))
    let (conductor, history) = try makeConductor(destination)
    // The row launch recovery leaves for a Dictation an earlier run transcribed: origin recovered,
    // with its text, never typed (#4). Written through History's own API, as HistoryStoreTests does.
    let id = DictationID()
    history.record(.began(id, origin: .recovered, purpose: .type, at: Date(), app: .unknown))
    history.record(.audioEnded(id, audio))
    history.record(.textReady(id, TextVersions(model: spokenText, cleaned: cleanedText),
                              cleanup: .rulesOnly(.off), model: parakeet, typing: false))
    await history.flush()
    #expect(await history.dictation(id)?.status == .recovered)

    await conductor.pasteLast()
    await history.flush()

    #expect(await destination.pasteCalls == [PasteCall(text: cleanedText, id: id)])
    #expect(await history.dictation(id)?.status == .inserted)
}
