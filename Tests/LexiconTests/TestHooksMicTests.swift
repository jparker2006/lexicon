#if DEBUG
import Foundation
import Testing
@testable import AudioCapture
@testable import LexiconCore
import History
import LexiconDomain

// The `mic zeros` test hook (#156): the next Dictation's mic delivers digital
// zeros, as a dead or contended mic does, and the one after it is the mic again.

@Test(.timeLimit(.minutes(1)))
func aSilencedMicGivesTheNextDictationOnlyZerosAndTheOneAfterTheMic() async throws {
    let rig = try HookRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    rig.recorder.silenceNextMicrophoneCapture()
    let silent = try await hold(rig, &events)
    let heard = try await hold(rig, &events)
    await rig.settle()

    let zeros = try CAFFile.read(rig.history.audioURL(for: silent)).samples
    #expect(!zeros.isEmpty)
    #expect(zeros.allSatisfy { $0 == 0 })
    #expect(try CAFFile.read(rig.history.audioURL(for: heard)).samples.contains { $0 != 0 })
}

/// One fn press through the hooks, to its end. Returns its Dictation.
private func hold(_ rig: HookRig, _ events: inout AsyncStream<ConductorEvent>.Iterator) async throws -> DictationID {
    rig.keyboard.press(.fnDown(shift: false))
    let started = await rig.until(\.isStarted, in: &events)
    rig.keyboard.press(.fnUp(shift: false))
    _ = await rig.until(\.isFinished, in: &events)
    return try #require(started.compactMap(\.startedID).first)
}
#endif
