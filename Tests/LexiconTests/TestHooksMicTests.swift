#if DEBUG
import Foundation
import Synchronization
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
    let (silent, silentEvents) = try await hold(rig, &events)
    let (heard, _) = try await hold(rig, &events)
    await rig.settle()

    // Zeros are a dead mic, not a quiet room: said so, never transcribed, the audio kept (#144).
    #expect(silentEvents.contains { $0.isMicSilent })
    #expect(!silentEvents.contains { $0.isFinished })
    #expect(try #require(await rig.history.dictation(silent)).status == .failed)
    #expect(try await statusReason(rig.history, silent) == "microphone: zeros")
    #expect(await rig.destination.delivered[silent] == nil)
    let zeros = try CAFFile.read(rig.history.audioURL(for: silent)).samples
    #expect(!zeros.isEmpty)
    #expect(zeros.allSatisfy { $0 == 0 })
    #expect(try CAFFile.read(rig.history.audioURL(for: heard)).samples.contains { $0 != 0 })
    #expect(await rig.destination.delivered[heard] != nil)
}

@Test(.timeLimit(.minutes(1)))
func aMicThatRunsButDeliversNothingFailsWithTheNotice() async throws {
    // The engine starts and runs, but not one buffer arrives, and no configuration change says why.
    let rig = try HookRig(hardware: FakeMic(mute: [0]).hardware)
    var events = await rig.conductor.events().makeAsyncIterator()

    let (silent, seen) = try await hold(rig, &events)
    await rig.settle()

    #expect(seen.contains { $0.isMicSilent })
    #expect(try #require(await rig.history.dictation(silent)).status == .failed)
    #expect(try await statusReason(rig.history, silent) == "microphone: noFrames")
    #expect(await rig.destination.delivered[silent] == nil)
}

@Test(.timeLimit(.minutes(1)))
func aSilencedMicIsSpentByADictationWhoseMicFailsToStart() async throws {
    // No input device for the first start only, as when a mic is unplugged.
    var hardware = FakeMic().hardware
    let finds = Mutex(0)
    hardware.findDevice = { _ in finds.withLock { $0 += 1; return $0 == 1 ? nil : 1 } }
    let rig = try HookRig(hardware: hardware)
    var events = await rig.conductor.events().makeAsyncIterator()

    rig.recorder.silenceNextMicrophoneCapture()
    rig.keyboard.press(.fnDown(shift: false))
    _ = await rig.until(\.isMicUnavailable, in: &events)
    rig.keyboard.press(.fnUp(shift: false))
    let (heard, _) = try await hold(rig, &events)
    await rig.settle()

    #expect(try CAFFile.read(rig.history.audioURL(for: heard)).samples.contains { $0 != 0 })
}

/// One fn press through the hooks, to its end: finished, or failed for a silent mic, which
/// ends on its notice alone. Returns its Dictation and the events after fn-down.
private func hold(_ rig: HookRig, _ events: inout AsyncStream<ConductorEvent>.Iterator) async throws
    -> (DictationID, [ConductorEvent])
{
    rig.keyboard.press(.fnDown(shift: false))
    let started = await rig.until(\.isStarted, in: &events)
    rig.keyboard.press(.fnUp(shift: false))
    let ended = await rig.until({ $0.isFinished || $0.isMicSilent }, in: &events)
    return (try #require(started.compactMap(\.startedID).first), ended)
}
extension ConductorEvent {
    var isMicUnavailable: Bool { if case .notice(.microphoneUnavailable) = self { true } else { false } }
    var isMicSilent: Bool { if case .notice(.microphoneSilent) = self { true } else { false } }
}
#endif
