import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import AppText
import Cleanup
import History
import KeyInput
import LexiconDomain
import Transcription
import WordStore

@Test(.timeLimit(.minutes(1)))
func aStopQueuedBeforeMicStartCompletesStillTypesItsAudio() async throws {
    let rig = try QueuedMicEndRig()
    defer { rig.mic.unwedge() }
    var events = await rig.conductor.events().makeAsyncIterator()
    var starts = rig.mic.wedged.makeAsyncIterator()
    let id = DictationID()

    await rig.conductor.handle(.dictationBegan(id, at: HostTime(nanoseconds: 0)))
    _ = try #require(await starts.next())
    let run = try #require(await rig.conductor.inFlight[id])
    await rig.conductor.handle(.dictationConfirmed(id, .hold))
    await rig.conductor.handle(.dictationStopped(id, at: HostTime(nanoseconds: 600_000_000)))

    rig.mic.unwedge()
    await waitForStarted(id, events: &events)
    let result = await run.value
    await rig.recorder.settle()
    await rig.history.flush()

    #expect(result.status == .inserted)
    #expect(result.versions?.model.isEmpty == false)
    #expect(await rig.destination.typedOrder == [id])
    let row = try #require(await rig.history.dictation(id))
    #expect(row.status == .inserted)
    #expect(row.finalText?.isEmpty == false)
    #expect(await rig.destination.delivered[id] == row.finalText)
    #expect(try CAFFile.read(rig.history.audioURL(for: id)).samples.count > 0)
}

@Test(.timeLimit(.minutes(1)))
func aDiscardQueuedBeforeMicStartCompletesLeavesNoRowFileOrText() async throws {
    let rig = try QueuedMicEndRig()
    defer { rig.mic.unwedge() }
    var events = await rig.conductor.events().makeAsyncIterator()
    var starts = rig.mic.wedged.makeAsyncIterator()
    let id = DictationID()

    await rig.conductor.handle(.dictationBegan(id, at: HostTime(nanoseconds: 0)))
    _ = try #require(await starts.next())
    let run = try #require(await rig.conductor.inFlight[id])
    await rig.conductor.handle(.dictationDiscarded(id))

    rig.mic.unwedge()
    await waitForStarted(id, events: &events)
    let result = await run.value
    await rig.recorder.settle()
    await rig.history.flush()

    #expect(result.status == nil)
    #expect(result.versions == nil)
    #expect(await rig.history.dictation(id) == nil)
    #expect(!FileManager.default.fileExists(atPath: rig.history.audioURL(for: id).path(percentEncoded: false)))
    #expect(try cafFiles(in: rig.history).isEmpty)
    #expect(await rig.destination.typedOrder.isEmpty)
    #expect(await rig.destination.delivered.isEmpty)
}

private struct QueuedMicEndRig {
    let mic: FakeMic
    let recorder: Recorder
    let history: HistoryStore
    let destination: HeadlessDestination
    let conductor: Conductor<HeadlessDestination>

    init() throws {
        let clock = TestClock()
        let mic = FakeMic(wedgesAtStart: [0], clock: clock)
        let paths = AppPaths.temporary()
        let recorder = Recorder(hardware: mic.hardware)
        let history = try HistoryStore(paths: paths)
        let destination = HeadlessDestination()
        self.mic = mic
        self.recorder = recorder
        self.history = history
        self.destination = destination
        conductor = Conductor(
            recorder: recorder, speech: SpeechEngine(local: ScriptedTranscriber(text: "Ship it"), clock: TestClock()),
            cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: history, destination: destination,
            preferences: PreferencesStore(fixed: .defaults), secrets: Secrets(.environment), keyboard: nil,
            fixes: nil, jev: nil)
    }
}

private func waitForStarted(_ id: DictationID, events: inout AsyncStream<ConductorEvent>.Iterator) async {
    while let event = await events.next() {
        if case .started(let started) = event, started == id { return }
    }
    Issue.record("the microphone start should complete")
}

private func cafFiles(in history: HistoryStore) throws -> [URL] {
    let folder = history.audioURL(for: DictationID()).deletingLastPathComponent()
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "caf" }
}
