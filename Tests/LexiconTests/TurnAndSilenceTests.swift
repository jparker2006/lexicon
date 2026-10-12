import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import LexiconDomain
import Transcription

// The insert turn and silence rules of the Conductor (#18, #4), headless: the real
// Conductor on a synthesized WAV, a scripted or held engine, a destination that
// records text. No mic, keys or network.

@Test(.timeLimit(.minutes(1)))
func aDictationStillWaitingGivesUpItsTurnSoALaterOneStillTypes() async throws {
    // A waiting Dictation gives up its place in the insert order, so a later one types without waiting for it (#18).
    let model = GatedFailingModel()
    let source = syntheticSamples(count: 19_200)
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: model, clock: TestClock())
    var events = await system.conductor.events().makeAsyncIterator()

    let firstRun = Task { await system.conductor.dictate(file: wav, pace: .asFastAsPossible) }
    await model.firstAnswerIsHeld()  // the first Dictation is still running and holds its turn

    let secondRun = Task { await system.conductor.dictate(file: wav, pace: .asFastAsPossible) }
    var started = 0
    // `.started` is emitted after the Conductor puts a Dictation in the insert order, so both are queued once two arrive.
    while started < 2, let event = await events.next() {
        if case .started = event { started += 1 }
    }
    await model.letTheFirstAnswerFail()  // the first now goes waiting while the second is queued behind it

    let first = await firstRun.value
    let second = await secondRun.value
    await system.history.flush()

    #expect(first.status == .waiting)  // the first kept its audio and gave up its turn
    #expect(second.status == .inserted)  // the later Dictation typed without waiting for the first
    #expect(await system.conductor.destination.typedOrder == [second.id])
    #expect(await system.conductor.destination.delivered[second.id] == second.versions?.cleaned)
    let row = try #require(await system.history.dictation(first.id))
    #expect(row.status == .waiting)
    #expect(row.audio == .onDisk)
    #expect(try CAFFile.read(system.history.audioURL(for: first.id)).samples == source)
}

@Test(.timeLimit(.minutes(1)))
func aModelAnswerWithNoWordsTypesNothingAndKeepsTheAudioForRetry() async throws {
    // An empty answer is silence, not text: nothing is typed, and the row keeps its audio so Retry can hear it again (#4).
    let source = syntheticSamples(count: 19_200)
    let wav = try writeWAV(source, rate: 16_000, in: try scratchDirectory())
    // The engine's own empty answer. "Um." (HeadlessDictationTests) gets past the engine, and Cleanup strips it.
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults,
                                         local: ScriptedTranscriber(text: ""), clock: TestClock())
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .failed)
    #expect(await system.conductor.destination.typedOrder.isEmpty)
    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .failed)
    #expect(try await statusReason(system.history, result.id) == "silence")
    #expect(row.audio == .onDisk)
    #expect(try CAFFile.read(system.history.audioURL(for: result.id)).samples == source)
    #expect(await system.history.clip(result.id) != nil)  // Retry can read the whole audio back
    var notices: [Notice] = []
    var finished: DictationStatus?
    for await event in events {
        if case .notice(let notice) = event { notices.append(notice) }
        if case .finished(_, let status) = event { finished = status; break }
    }
    #expect(finished == .failed)  // the pill's "No speech heard"
    #expect(!notices.contains(.readyToPaste(result.id)))  // nothing is waiting in paste-last
}

/// Its first answer is held until the test lets it go, then fails as a missing model does.
/// Every later answer hears "Ship it.".
private actor GatedFailingModel: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var calls = 0
    private let heldEvents: AsyncStream<Void>
    private let heldSignal: AsyncStream<Void>.Continuation
    private let gateEvents: AsyncStream<Void>
    private let gateSignal: AsyncStream<Void>.Continuation

    init() {
        let held = AsyncStream<Void>.makeStream()
        heldEvents = held.stream
        heldSignal = held.continuation
        let gate = AsyncStream<Void>.makeStream()
        gateEvents = gate.stream
        gateSignal = gate.continuation
    }

    var isResident: Bool { true }
    func load() {}
    func unload() {}

    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) async throws -> String {
        calls += 1
        guard calls == 1 else { return "Ship it." }
        heldSignal.yield(())
        var gate = gateEvents.makeAsyncIterator()
        _ = await gate.next()
        throw LocalModelNotInstalled(model)
    }

    /// Returns once the first answer is held at the gate.
    func firstAnswerIsHeld() async {
        var held = heldEvents.makeAsyncIterator()
        _ = await held.next()
    }

    /// Lets the held first answer go on to fail.
    func letTheFirstAnswerFail() {
        gateSignal.yield(())
    }
}
