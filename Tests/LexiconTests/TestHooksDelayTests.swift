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
#endif
