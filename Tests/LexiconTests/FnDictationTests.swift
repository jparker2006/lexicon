import Foundation
import Synchronization
import Testing
@testable import AudioCapture
@testable import KeyInput
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
import Transcription
import WordStore

// The fn key to History and the cursor (#53), headless: the real recognizer feeds
// the real Conductor through its key loop, on a fake mic and a scripted model.
// No mic, keys or network.

@Test(.timeLimit(.minutes(1)))
func loneTapLeavesNoHistoryRowAndNoAudioFile() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false, id: DictationID()), .fnUp(fnAt(90))]))
    let started = await awaitStart(&events)
    let id = try #require(started)
    await settleFn(rig)

    #expect(await rig.history.dictation(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: rig.history.audioURL(for: id).path(percentEncoded: false)))
    #expect(try cafFiles(in: rig.history).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func shortcutWithinTheThresholdLeavesNothing() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    // fn+arrow: the key lands inside the hold threshold, so the tap is discarded.
    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false, id: DictationID()), .otherKey(fnAt(120)), .fnUp(fnAt(400))]))
    let started = await awaitStart(&events)
    let id = try #require(started)
    await settleFn(rig)

    #expect(await rig.history.dictation(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: rig.history.audioURL(for: id).path(percentEncoded: false)))
    #expect(try cafFiles(in: rig.history).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func holdTypesTheTextAndKeepsTheRow() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false, id: DictationID()), .deadline(fnAt(300)), .fnUp(fnAt(600))]))
    // Confirmed and stopped are sent before the run announces itself, so read from the first event.
    let seen = await eventsUntilFinished(&events)
    let started = startedID(in: seen)
    let id = try #require(started)
    await settleFn(rig)

    #expect(seen.contains(where: { event in
        if case .confirmed(let who, .hold) = event { who == id } else { false }
    }))
    #expect(seen.contains(where: { event in
        if case .finished(let who, .inserted) = event { who == id } else { false }
    }))

    let row = try #require(await rig.history.dictation(id))
    #expect(row.status == .inserted)
    #expect(row.versions?.model == "Ship it")
    #expect(await rig.destination.delivered[id] == row.finalText)
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
}

@Test(.timeLimit(.minutes(1)))
func secureInputFnDownStartsNoDictation() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: true, id: DictationID()), .fnUp(fnAt(600))]))
    await settleFn(rig)
    #expect(await rig.conductor.inFlight.isEmpty)
    #expect(try cafFiles(in: rig.history).isEmpty)

    // A Dictation that had begun would have announced itself first, so the first
    // `.started` from here on must be the one this file Dictation starts.
    let wav = try writeWAV(syntheticSamples(count: 8_000), rate: 16_000, in: try scratchDirectory())
    let next = await rig.conductor.dictate(file: wav, pace: .asFastAsPossible)
    let started = await awaitStart(&events)
    #expect(started == next.id)
}

@Test(.timeLimit(.minutes(1)))
func aCommandForAnotherPressNeverEndsTheRecording() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()
    let held = DictationID(), stray = DictationID()

    await rig.conductor.handle(.dictationBegan(held, at: fnAt(0)))
    #expect(await awaitStart(&events) == held)
    // A press the Conductor never started (its begin came while `held` was recording) ends nothing.
    await rig.conductor.handle(.dictationBegan(stray, at: fnAt(400)))
    await rig.conductor.handle(.dictationDiscarded(stray))
    await rig.conductor.handle(.dictationStopped(stray, at: fnAt(450)))
    await rig.conductor.handle(.dictationConfirmed(held, .hold))
    await rig.conductor.handle(.dictationStopped(held, at: fnAt(900)))
    await settleFn(rig)

    let row = try #require(await rig.history.dictation(held))
    #expect(row.status == .inserted)
    #expect(await rig.history.dictation(stray) == nil)
    #expect(try cafFiles(in: rig.history).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func sleepWithTheNextPressStillQueuedKeepsThatDictation() async throws {
    // The Mac sleeps while fn-up of one hold and fn-down of the next sit in the
    // command stream, unread. The next press must
    // still be its own Dictation, and a later lone tap must not delete it.
    let keys = ScriptedKeys()
    let rig = try FnRig(keyboard: keys.keyboard)
    var events = await rig.conductor.events().makeAsyncIterator()
    var commands = keys.keyboard.commands.makeAsyncIterator()
    let first = DictationID(), second = DictationID(), tap = DictationID()

    keys.press(.fnDown(fnAt(0), secureInput: false, id: first), .deadline(fnAt(300)))
    for _ in 0..<2 { await rig.conductor.handle(try #require(await commands.next())) }
    #expect(await awaitStart(&events) == first)

    keys.press(.fnUp(fnAt(600)), .fnDown(fnAt(700), secureInput: false, id: second))
    await rig.conductor.systemWillSleep()
    keys.press(.fnUp(fnAt(1_500)), .fnDown(fnAt(1_800), secureInput: false, id: tap), .fnUp(fnAt(1_850)))
    keys.end()
    while let command = await commands.next() { await rig.conductor.handle(command) }
    await settleFn(rig)

    #expect(try #require(await rig.history.dictation(first)).status == .inserted)
    let kept = try #require(await rig.history.dictation(second))
    #expect(kept.versions?.model == "Ship it")
    #expect(await rig.history.dictation(tap) == nil)
    #expect(try cafFiles(in: rig.history).count == 2)
}

@Test(.timeLimit(.minutes(1)))
func quitWaitsForTheRecordingDictationToLand() async throws {
    let rig = try FnRig()
    var events = await rig.conductor.events().makeAsyncIterator()
    let id = DictationID()

    await rig.conductor.handle(.dictationBegan(id, at: fnAt(0)))
    #expect(await awaitStart(&events) == id)
    let quitting = Task { await rig.conductor.idle() }
    await rig.conductor.handle(.dictationConfirmed(id, .hold))
    await rig.conductor.handle(.dictationStopped(id, at: fnAt(600)))
    await quitting.value

    // Nothing else waited: `idle` alone leaves the row written and the audio closed.
    #expect(await rig.history.dictation(id)?.status == .inserted)
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
}

@Test(.timeLimit(.minutes(1)))
func backToBackDictationsTypeInTheOrderTheyWereSpoken() async throws {
    // The first Dictation's text comes last: it still types first (#18).
    let model = HeldFirstTranscriber()
    let rig = try FnRig(local: model)
    let first = DictationID(), second = DictationID()

    for command: KeyCommand in [.dictationBegan(first, at: fnAt(0)), .dictationConfirmed(first, .hold),
                                .dictationStopped(first, at: fnAt(600))] {
        await rig.conductor.handle(command)
    }
    await model.waitForCalls(1)  // the first is in the model, held
    for command: KeyCommand in [.dictationBegan(second, at: fnAt(700)), .dictationConfirmed(second, .hold),
                                .dictationStopped(second, at: fnAt(1_300))] {
        await rig.conductor.handle(command)
    }
    await model.waitForCalls(2)  // the second has its text while the first is still in the model
    await model.releaseFirst()
    await settleFn(rig)

    #expect(await rig.destination.typedOrder == [first, second])
    #expect(await rig.destination.delivered[first] == "First.")
    #expect(await rig.destination.delivered[second] == "Second.")
}

@Test(.timeLimit(.minutes(1)))
func quitDoesNotWaitForeverOnADictationStuckInTheModel() async throws {
    let model = HeldFirstTranscriber()  // never lets go of the first clip
    let rig = try FnRig(local: model)
    let id = DictationID()

    for command: KeyCommand in [.dictationBegan(id, at: fnAt(0)), .dictationConfirmed(id, .hold),
                                .dictationStopped(id, at: fnAt(600))] {
        await rig.conductor.handle(command)
    }
    await model.waitForCalls(1)
    await rig.conductor.idle(finishingWithin: .milliseconds(100))

    // Not lost: the row and its audio are on disk for launch recovery.
    #expect(await rig.history.dictation(id)?.status == .transcribing)
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
    await model.releaseFirst()
}

/// The real recognizer behind a `Keyboard`, fed by the test instead of the fn tap.
private final class ScriptedKeys: Sendable {
    let keyboard: Keyboard
    private let continuation: AsyncStream<KeyCommand>.Continuation

    init() {
        let (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
        let gesture = Gesture()
        keyboard = Keyboard(commands: commands, feed: { input in
            for command in gesture.handle(input) { continuation.yield(command) }
        })
        self.continuation = continuation
    }

    func press(_ inputs: KeyInput...) { for input in inputs { keyboard.feed(input) } }
    func end() { continuation.finish() }
}

/// One recognizer behind a lock, so the test and the Conductor can both feed it.
private final class Gesture: Sendable {
    private let gesture = Mutex(FnGesture(holdThreshold: KeyboardConfig().holdThreshold))
    func handle(_ input: KeyInput) -> [KeyCommand] { gesture.withLock { $0.handle(input).commands } }
}

/// The real Conductor on a fake mic, a scripted model and a recording destination,
/// with History and its audio under a throwaway folder.
private struct FnRig {
    let recorder: Recorder
    let history: HistoryStore
    let destination: HeadlessDestination
    let conductor: Conductor<HeadlessDestination>

    init(keyboard: Keyboard? = nil, local: any LocalTranscriber = ScriptedTranscriber(text: "Ship it")) throws {
        let paths = AppPaths.temporary()
        let recorder = Recorder(hardware: FakeMic().hardware)
        let history = try HistoryStore(paths: paths)
        let destination = HeadlessDestination()
        self.recorder = recorder
        self.history = history
        self.destination = destination
        conductor = Conductor(
            recorder: recorder, speech: SpeechEngine(local: local), cleanup: Cleanup(),
            lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
            keyboard: keyboard, fixes: nil, jev: nil)
    }
}

/// Hears "First." then "Second.", but holds the first answer until the test lets it go.
private actor HeldFirstTranscriber: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var calls = 0
    private var held: CheckedContinuation<Void, Never>?
    private var released = false

    var isResident: Bool { true }
    func load() {}
    func unload() {}

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async -> String {
        calls += 1
        guard calls == 1 else { return "Second." }
        if !released { await withCheckedContinuation { held = $0 } }
        return "First."
    }

    func waitForCalls(_ count: Int) async {
        while calls < count { await Task.yield() }
    }

    func releaseFirst() {
        released = true
        held?.resume()
        held = nil
    }
}

/// The fake clock. fn-down is two seconds before now and every later fn event is
/// placed after it, so all of them are in the past when the Conductor reads them,
/// as real ones are: a fn-up in the future would stretch the capture tail (`Tail`).
private let fnZero = HostTime(nanoseconds: HostTime.now().nanoseconds - 2_000_000_000)

/// `milliseconds` after fn-down.
private func fnAt(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: fnZero.nanoseconds + UInt64(milliseconds) * 1_000_000)
}

/// The commands the fn tap would deliver for `inputs`: one recognizer, then the end of the stream.
private func fnCommands(_ inputs: [KeyInput]) -> AsyncStream<KeyCommand> {
    var gesture = FnGesture(holdThreshold: KeyboardConfig().holdThreshold)
    let (stream, continuation) = AsyncStream<KeyCommand>.makeStream()
    for input in inputs {
        for command in gesture.handle(input).commands { continuation.yield(command) }
    }
    continuation.finish()
    return stream
}

/// The id of the next Dictation to begin. Only read where one is certain to begin.
private func awaitStart(_ events: inout AsyncStream<ConductorEvent>.Iterator) async -> DictationID? {
    while let event = await events.next() {
        if case .started(let id) = event { return id }
    }
    return nil
}

/// The Dictation that began among `events`, if any.
private func startedID(in events: [ConductorEvent]) -> DictationID? {
    for event in events {
        if case .started(let id) = event { return id }
    }
    return nil
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

/// Waits for every Dictation still running to return, then for the audio writer to
/// close its files, then for History to apply every event recorded so far.
private func settleFn(_ rig: FnRig) async {
    let runs = await rig.conductor.inFlight
    for run in runs.values { _ = await run.value }
    await rig.recorder.settle()
    await rig.history.flush()
}

/// The audio files in History's folder. A Dictation's audio can only be there.
private func cafFiles(in history: HistoryStore) throws -> [URL] {
    let folder = history.audioURL(for: DictationID()).deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "caf" }
}
