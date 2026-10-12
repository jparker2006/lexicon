#if DEBUG
import Foundation
import Testing
@testable import LexiconCore
import LexiconDomain
import Transcription

// `hook dictate <wav> --result-delay <ms>` (#156): the local model's next live
// answer is held for the delay, so the Dictation is still transcribing while a
// check switches apps or presses keys. The delay runs on a test clock.

@Test(.timeLimit(.minutes(1)))
func aResultDelayHoldsTheTextUntilTheDelayHasPassed() async throws {
    let clock = TestClock()
    let model = SlowedTranscriber(ScriptedTranscriber(text: "Ship it."), clock: clock)
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: model)
    let wav = try writeWAV(tone(16_000), rate: 16_000, in: try scratchDirectory())

    model.slowNext(by: .milliseconds(1_500))
    let first = Task { await system.conductor.dictate(file: wav, pace: .asFastAsPossible) }
    await clock.waitForSleep(endingAt: .milliseconds(1_500))
    #expect(await system.conductor.destination.delivered.isEmpty)

    await clock.advance(by: .milliseconds(1_500))
    #expect(await first.value.status == .inserted)
    // Once only: the next Dictation is not held.
    #expect(await system.conductor.dictate(file: wav, pace: .asFastAsPossible).status == .inserted)
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1)))
func aDelayedAnswerThatFailsSpendsTheDelay() async throws {
    // The clock never moves: a held answer would hang until the time limit.
    let model = SlowedTranscriber(FailsOnce(), clock: TestClock())
    model.slowNext(by: .seconds(120))
    let clip = AudioClip(samples: tone(16_000))
    await #expect(throws: LocalModelNotInstalled.self) {
        try await model.transcribe(clip, terms: [], priority: .live)
    }
    #expect(try await model.transcribe(clip, terms: [], priority: .live) == "Ship it.")
}

/// A model not installed at the first call, as before setup finishes, and installed after.
private actor FailsOnce: LocalTranscriber {
    nonisolated let model = LocalModel.parakeetUnified
    private var calls = 0
    var isResident: Bool { true }
    func load() {}
    func unload() {}
    func transcribe(_ clip: AudioClip, terms: [Term], priority: LocalPriority) throws -> String {
        calls += 1
        if calls == 1 { throw LocalModelNotInstalled(model) }
        return "Ship it."
    }
}
#endif
