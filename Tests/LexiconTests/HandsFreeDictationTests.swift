import Foundation
import LexiconUI
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

// Hands-free, Esc and the cap (#58), headless: the real recognizer feeds the real
// Conductor through an open stream of commands, one scripted input at a time. A test
// awaits what the Conductor did before it feeds the next press. Fake mic, scripted
// model, recording destination, History under a throwaway folder. No mic, keys or network.
//
// Each step checks the recognizer's answer to its input before it awaits the Conductor,
// so a behavior that is not built yet fails on that answer, not on a wait that never ends.

@Test(.timeLimit(.minutes(1)))
func escSavesAnUntypedDictation() async throws {
    // Esc in a confirmed hold cancels the recording. The Dictation is still transcribed and
    // kept as not inserted, so paste-last can get it back, and nothing is typed.
    let rig = try HandsFreeRig()
    var events = await rig.conductor.events().makeAsyncIterator()
    let id = DictationID()
    var seen: [ConductorEvent] = []

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: id)).commands == [.dictationBegan(id, at: at(0))])
    seen += await readUntil(&events) { event in if case .started(let who) = event { who == id } else { false } }
    try #require(rig.feed(.deadline(at(300))).commands == [.dictationConfirmed(id, .hold)])
    seen += await readUntil(&events) { event in if case .confirmed(let who, .hold) = event { who == id } else { false } }
    try #require(rig.feed(.escape(at(1_000))).commands == [.dictationCancelled(id)])
    seen += await readUntil(&events) { event in if case .finished = event { true } else { false } }
    await rig.settle()

    #expect(seen.contains(where: { event in
        if case .notice(.readyToPaste(let who)) = event { who == id } else { false }
    }))
    #expect(seen.contains(where: { event in
        if case .finished(let who, .notInserted) = event { who == id } else { false }
    }))
    let row = try #require(await rig.history.dictation(id))
    #expect(row.status == .notInserted)
    #expect(row.versions?.model == "Ship it")
    #expect(await rig.destination.delivered[id] == nil)
    #expect(await rig.destination.typedOrder.isEmpty)
    // The audio is kept, so the text can be made again.
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
    #expect(try cafFiles(in: rig.history).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aDoubleTapIsOneHandsFreeDictation() async throws {
    // Two taps, the second press 200 ms in (inside the 250 ms window after the first fn-up),
    // make one hands-free Dictation. The second press confirms the first and begins no Dictation
    // of its own, and a later fn-down stops the recording.
    let rig = try HandsFreeRig()
    var events = await rig.conductor.events().makeAsyncIterator()
    let first = DictationID(), second = DictationID(), stop = DictationID()
    var seen: [ConductorEvent] = []

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: first)).commands == [.dictationBegan(first, at: at(0))])
    seen += await readUntil(&events) { event in if case .started(let who) = event { who == first } else { false } }
    try #require(rig.feed(.fnUp(at(100))).commands == [])  // a tap: nothing ends yet, the window is open
    try #require(rig.feed(.fnDown(at(200), secureInput: false, id: second)).commands
        == [.dictationConfirmed(first, .handsFree)])
    seen += await readUntil(&events) { event in
        if case .confirmed(let who, .handsFree) = event { who == first } else { false }
    }
    try #require(rig.feed(.fnUp(at(300))).commands == [])  // hands-free: a release does nothing
    try #require(rig.feed(.fnDown(at(2_000), secureInput: false, id: stop)).commands
        == [.dictationStopped(first, at: at(2_000))])
    seen += await readUntil(&events) { event in if case .finished = event { true } else { false } }
    await rig.settle()

    #expect(startedIDs(seen) == [first])
    #expect(seen.contains(where: { event in
        if case .confirmed(let who, .handsFree) = event { who == first } else { false }
    }))
    let row = try #require(await rig.history.dictation(first))
    #expect(row.status == .inserted)
    #expect(await rig.destination.delivered[first] == "Ship it")
    #expect(await rig.history.dictation(second) == nil)
    #expect(await rig.history.dictation(stop) == nil)
    #expect(try cafFiles(in: rig.history).count == 1)
}

@Test(.timeLimit(.minutes(1)))
func theCapWarnsOnceThenStopsAndInsertsAHandsFreeDictation() async throws {
    // A shortened cap: 10 s, with the warning 2 s before it. Both count from the first fn-down,
    // so the warning is due at 8 s and the stop at 10 s, whatever the second press did.
    let rig = try HandsFreeRig(config: KeyboardConfig(cap: .seconds(10), capWarning: .seconds(2)))
    var events = await rig.conductor.events().makeAsyncIterator()
    let first = DictationID(), second = DictationID()
    var seen: [ConductorEvent] = []

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: first)).commands == [.dictationBegan(first, at: at(0))])
    seen += await readUntil(&events) { event in if case .started(let who) = event { who == first } else { false } }
    try #require(rig.feed(.fnUp(at(100))).commands == [])
    try #require(rig.feed(.fnDown(at(200), secureInput: false, id: second)).commands
        == [.dictationConfirmed(first, .handsFree)])
    seen += await readUntil(&events) { event in
        if case .confirmed(let who, .handsFree) = event { who == first } else { false }
    }
    try #require(rig.feed(.fnUp(at(300))).commands == [])
    // The warning mark: began + cap - capWarning.
    try #require(rig.feed(.deadline(at(8_050))).commands == [.oneMinuteLeft(first)])
    seen += await readUntil(&events) { event in if case .oneMinuteLeft(let who) = event { who == first } else { false } }
    // The cap mark: began + cap.
    try #require(rig.feed(.deadline(at(10_050))).commands == [.dictationStopped(first, at: at(10_000))])
    seen += await readUntil(&events) { event in if case .finished = event { true } else { false } }
    await rig.settle()

    // The pill: the events the Conductor sent, applied in order, the way the indicator applies them.
    var follower = IndicatorFollower()
    var pill: (state: IndicatorState, cue: SoundCue?)?
    for event in seen {
        let cue = follower.apply(event)
        if case .oneMinuteLeft = event { pill = (state: follower.state, cue: cue) }
    }
    let shown = try #require(pill)
    #expect(shown.state == .recording(.handsFree, minuteLeft: true))
    #expect(shown.cue == .warning)

    // The warning sounds once, before the stop.
    #expect(seen.count(where: { event in if case .oneMinuteLeft = event { true } else { false } }) == 1)
    let warned = try #require(seen.firstIndex(where: { event in
        if case .oneMinuteLeft = event { true } else { false }
    }))
    let stopped = try #require(seen.firstIndex(where: { event in
        if case .stopped(let who) = event { who == first } else { false }
    }))
    #expect(warned < stopped)

    let row = try #require(await rig.history.dictation(first))
    #expect(row.status == .inserted)
    #expect(await rig.destination.delivered[first] == "Ship it")
    #expect(await rig.history.dictation(second) == nil)
}

@Test(.timeLimit(.minutes(1)))
func theCapWarnsAndStopsAHeldDictationToo() async throws {
    // Both modes count the cap from the first fn-down: a hold gets the same 8 s warning and 10 s stop.
    let rig = try HandsFreeRig(config: KeyboardConfig(cap: .seconds(10), capWarning: .seconds(2)))
    var events = await rig.conductor.events().makeAsyncIterator()
    let id = DictationID()
    var seen: [ConductorEvent] = []

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: id)).commands == [.dictationBegan(id, at: at(0))])
    seen += await readUntil(&events) { event in if case .started(let who) = event { who == id } else { false } }
    try #require(rig.feed(.deadline(at(300))).commands == [.dictationConfirmed(id, .hold)])
    seen += await readUntil(&events) { event in if case .confirmed(let who, .hold) = event { who == id } else { false } }
    try #require(rig.feed(.deadline(at(8_050))).commands == [.oneMinuteLeft(id)])
    seen += await readUntil(&events) { event in if case .oneMinuteLeft(let who) = event { who == id } else { false } }
    try #require(rig.feed(.deadline(at(10_050))).commands == [.dictationStopped(id, at: at(10_000))])
    seen += await readUntil(&events) { event in if case .finished = event { true } else { false } }
    await rig.settle()

    let warned = try #require(seen.firstIndex(where: { event in
        if case .oneMinuteLeft = event { true } else { false }
    }))
    let stopped = try #require(seen.firstIndex(where: { event in
        if case .stopped(let who) = event { who == id } else { false }
    }))
    #expect(warned < stopped)
    let row = try #require(await rig.history.dictation(id))
    #expect(row.status == .inserted)
}

@Test(.timeLimit(.minutes(1)))
func aLostFnUpEndsAtTheCapAndQuitWaitsForIt() async throws {
    // No fn-up ever comes: the tap was disabled and nothing said so. The cap ends the hold at
    // 10 s (its mark acts 50 ms later), and Quit (`idle`) returns once it has.
    let rig = try HandsFreeRig(config: KeyboardConfig(cap: .seconds(10), capWarning: .seconds(2)))
    var events = await rig.conductor.events().makeAsyncIterator()
    let id = DictationID()
    var seen: [ConductorEvent] = []

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: id)).commands == [.dictationBegan(id, at: at(0))])
    seen += await readUntil(&events) { event in if case .started(let who) = event { who == id } else { false } }
    try #require(rig.feed(.deadline(at(300))).commands == [.dictationConfirmed(id, .hold)])
    seen += await readUntil(&events) { event in if case .confirmed(let who, .hold) = event { who == id } else { false } }

    // Quit while the press is held: it returns once the cap ends the press, with the row written.
    let conductor = rig.conductor
    let quitting = Task { await conductor.idle() }
    // Its warning's mark was never fed, so the cap warns first, then stops.
    try #require(rig.feed(.deadline(at(10_050))).commands == [.oneMinuteLeft(id), .dictationStopped(id, at: at(10_000))])
    await quitting.value
    await rig.settle()

    let row = try #require(await rig.history.dictation(id))
    #expect(row.status == .inserted)
    #expect(row.versions?.model == "Ship it")
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
}

@Test(.timeLimit(.minutes(1)))
func aHandsFreeDictationWhoseMicNeverStartsGivesEscBack() async throws {
    // The mic never starts, so the Conductor ends the hands-free Dictation itself. The recognizer
    // hears it: Esc reaches the apps again, and the next fn-down begins a new press instead of
    // stopping a Dictation that is already over.
    let clock = TestClock()
    let mic = FakeMic(wedgesAtStart: [0], clock: clock)
    defer { mic.unwedge() }  // never leave a thread blocked, even when an expectation fails
    let rig = try HandsFreeRig(hardware: mic.hardware)
    var events = await rig.conductor.events().makeAsyncIterator()
    var starts = mic.wedged.makeAsyncIterator()
    let first = DictationID(), next = DictationID()

    try #require(rig.feed(.fnDown(at(0), secureInput: false, id: first)).commands == [.dictationBegan(first, at: at(0))])
    rig.feed(.fnUp(at(90)))
    try #require(rig.feed(.fnDown(at(200), secureInput: false, id: DictationID())).commands
        == [.dictationConfirmed(first, .handsFree)])
    #expect(rig.recognizer.takesEscape)
    _ = try #require(await starts.next())
    await clock.waitForSleepers(1)
    await clock.advance(by: Microphone.startLimit)
    _ = await readUntil(&events) { event in if case .notice(.microphoneUnavailable) = event { true } else { false } }

    #expect(!rig.recognizer.takesEscape)
    try #require(rig.feed(.fnDown(at(5_000), secureInput: false, id: next)).commands == [.dictationBegan(next, at: at(5_000))])
    rig.feed(.fnUp(at(6_000)))
    _ = await readUntil(&events) { event in if case .finished(let who, _) = event { who == next } else { false } }
    await rig.settle()
    #expect(await rig.history.dictation(first)?.status == .failed)
    #expect(await rig.history.dictation(next)?.status == .inserted)
}

/// The real Conductor following an open stream of commands from one recognizer, which the
/// test feeds one input at a time. Fake mic, scripted model, recording destination, and
/// History under a throwaway folder.
private struct HandsFreeRig {
    let recorder: Recorder
    let history: HistoryStore
    let destination: HeadlessDestination
    let conductor: Conductor<HeadlessDestination>
    let recognizer: Recognizer

    init(config: KeyboardConfig = KeyboardConfig(), local: any LocalTranscriber = ScriptedTranscriber(text: "Ship it"),
         hardware: MicHardware = FakeMic().hardware) throws {
        let paths = AppPaths.temporary()
        let recognizer = Recognizer(config)
        let recorder = Recorder(hardware: hardware)
        let history = try HistoryStore(paths: paths)
        let destination = HeadlessDestination()
        let conductor = Conductor(
            recorder: recorder, speech: SpeechEngine(local: local, clock: TestClock()), cleanup: Cleanup(),
            lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
            keyboard: Keyboard(commands: recognizer.commands, feed: { _ = recognizer.feed($0) }), fixes: nil, jev: nil)
        self.recognizer = recognizer
        self.recorder = recorder
        self.history = history
        self.destination = destination
        self.conductor = conductor
        let commands = recognizer.commands
        Task { await conductor.follow(commands) }
    }

    /// Feeds one input to the recognizer. Returns what it did, including the deadline it asked for.
    @discardableResult
    func feed(_ input: KeyInput) -> FnGesture.Output { recognizer.feed(input) }

    /// Every Dictation run has returned, its audio is closed and History has caught up. Then the
    /// key stream ends, since nothing more is fed.
    func settle() async {
        let runs = await conductor.inFlight
        for run in runs.values { _ = await run.value }
        await recorder.settle()
        await history.flush()
        recognizer.end()
    }
}

/// One recognizer behind a lock, so the test can feed it between its awaits. Every command
/// it emits goes onto one stream, in order, for the Conductor's `follow`.
private final class Recognizer: Sendable {
    let commands: AsyncStream<KeyCommand>
    private let continuation: AsyncStream<KeyCommand>.Continuation
    private let gesture: Mutex<FnGesture>

    init(_ config: KeyboardConfig) {
        (commands, continuation) = AsyncStream<KeyCommand>.makeStream()
        gesture = Mutex(FnGesture(config))
    }

    /// Feeds one input and returns what the recognizer made of it. The commands are yielded
    /// inside the lock, so two feeds can never reach the stream out of order.
    func feed(_ input: KeyInput) -> FnGesture.Output {
        gesture.withLock { recognizer in
            let output = recognizer.handle(input)
            for command in output.commands { continuation.yield(command) }
            return output
        }
    }

    var takesEscape: Bool { gesture.withLock { $0.takesEscape } }

    func end() { continuation.finish() }
}

/// The fake clock. The first fn-down is sixty seconds in the past, and every later input is
/// placed after it, so all of them are in the past when the Conductor reads them: a cap mark
/// in the future would stretch the capture tail.
private let handsFreeZero: HostTime = {
    let now = HostTime.now().nanoseconds
    let sixtySeconds: UInt64 = 60_000_000_000
    return HostTime(nanoseconds: now > sixtySeconds ? now - sixtySeconds : 0)
}()

/// `milliseconds` after the first fn-down.
private func at(_ milliseconds: Int) -> HostTime {
    HostTime(nanoseconds: handsFreeZero.nanoseconds + UInt64(milliseconds) * 1_000_000)
}

/// The events up to and including the first that matches. Only called where the Conductor is
/// certain to send the match, because the recognizer's answer to the input was checked first.
private func readUntil(_ events: inout AsyncStream<ConductorEvent>.Iterator,
                       _ match: (ConductorEvent) -> Bool) async -> [ConductorEvent] {
    var seen: [ConductorEvent] = []
    while let event = await events.next() {
        seen.append(event)
        if match(event) { break }
    }
    return seen
}

/// The Dictations that began among `events`, in order.
private func startedIDs(_ events: [ConductorEvent]) -> [DictationID] {
    var ids: [DictationID] = []
    for event in events {
        if case .started(let id) = event { ids.append(id) }
    }
    return ids
}

/// The audio files in History's folder. A Dictation's audio can only be there.
private func cafFiles(in history: HistoryStore) throws -> [URL] {
    let folder = history.audioURL(for: DictationID()).deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "caf" }
}
