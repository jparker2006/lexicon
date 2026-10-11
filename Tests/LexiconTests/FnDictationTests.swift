import Foundation
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

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false), .fnUp(fnAt(90))]))
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
    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false), .otherKey(fnAt(120)), .fnUp(fnAt(400))]))
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

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: false), .deadline(fnAt(300)), .fnUp(fnAt(600))]))
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

    await rig.conductor.follow(fnCommands([.fnDown(fnAt(0), secureInput: true), .fnUp(fnAt(600))]))
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

/// The real Conductor on a fake mic, a scripted model and a recording destination,
/// with History and its audio under a throwaway folder.
private struct FnRig {
    let recorder: Recorder
    let history: HistoryStore
    let destination: HeadlessDestination
    let conductor: Conductor<HeadlessDestination>

    init() throws {
        let paths = AppPaths.temporary()
        let recorder = Recorder(hardware: FakeMic().hardware)
        let history = try HistoryStore(paths: paths)
        let destination = HeadlessDestination()
        self.recorder = recorder
        self.history = history
        self.destination = destination
        conductor = Conductor(
            recorder: recorder, speech: SpeechEngine(local: ScriptedTranscriber(text: "Ship it")), cleanup: Cleanup(),
            lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment),
            keyboard: nil, fixes: nil, jev: nil)
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
