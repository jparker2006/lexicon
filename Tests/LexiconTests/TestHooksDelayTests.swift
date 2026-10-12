#if DEBUG
import Foundation
import Testing
@testable import LexiconCore
import LexiconDomain
import Transcription

// `hook dictate <wav> --result-delay <ms>` (#156): the local model's next live
// answer is held for the delay, so the Dictation is still transcribing while a
// check switches apps or presses keys. The delay runs on a test clock.

/// The hook's delay, as a named length: a test-clock value, never waited for in real time.
private let delay = Duration.seconds(90)

@Test(.timeLimit(.minutes(1)))
func aResultDelayHoldsTheTextUntilTheDelayHasPassed() async throws {
    let clock = TestClock()
    let model = SlowedTranscriber(ScriptedTranscriber(text: "Ship it."), clock: clock)
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: model)
    let wav = try writeWAV(tone(16_000), rate: 16_000, in: try scratchDirectory())

    let first = Task { await model.slowing(by: delay) { await system.conductor.dictate(file: wav, pace: .asFastAsPossible) } }
    await clock.waitForSleep(endingAt: delay)
    #expect(await system.conductor.destination.delivered.isEmpty)

    await clock.advance(by: delay)
    #expect(await first.value.status == .inserted)
    // Once only: the next Dictation is not held.
    #expect(await system.conductor.dictate(file: wav, pace: .asFastAsPossible).status == .inserted)
    #expect(clock.sleepers == 0)
}

@Test(.timeLimit(.minutes(1)))
func aDelayedDictationThatNeverReachesTheModelLeavesTheNextOneUnheld() async throws {
    // The clock never moves: a held answer would hang until the time limit.
    let model = SlowedTranscriber(ScriptedTranscriber(text: "Ship it."), clock: TestClock())
    let system = try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: model)
    let unreadable = try scratchDirectory().appending(path: "fixtures/missing.wav")

    _ = await model.slowing(by: delay) { await system.conductor.dictate(file: unreadable, pace: .asFastAsPossible) }

    let wav = try writeWAV(tone(16_000), rate: 16_000, in: try scratchDirectory())
    #expect(await system.conductor.dictate(file: wav, pace: .asFastAsPossible).status == .inserted)
}

@Test(.timeLimit(.minutes(1)))
func aDelayedAnswerThatFailsSpendsTheDelay() async throws {
    let model = SlowedTranscriber(FailsOnce(), clock: TestClock())
    let clip = AudioClip(samples: tone(16_000))
    let second = await model.slowing(by: delay) { () async -> String? in
        _ = try? await model.transcribe(clip, terms: [], priority: .live)  // not installed yet
        return try? await model.transcribe(clip, terms: [], priority: .live)
    }
    #expect(second == "Ship it.")
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
