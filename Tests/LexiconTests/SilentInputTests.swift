import AudioCapture
import Foundation
import History
@testable import LexiconCore
import LexiconDomain
import Testing
import Transcription

// The zero-input notice (#144). Capture: a take whose every frame is digital zero
// says so. Headless: a Dictation whose input is all zeros fails as a silent mic,
// keeps its audio, is never transcribed, and shows the notice. A quiet input that
// is never zero, and one whose sound comes after its first 0.5 s, land as usual.
// File input only: no mic, keys or network.

private let rate = 16_000

/// `count` samples of digital silence.
private func zeroSamples(count: Int) -> [Int16] { [Int16](repeating: 0, count: count) }

/// `count` samples of a 440 Hz tone at amplitude 8,000, as a mic delivers when Jake is talking.
private func loudTone(count: Int) -> [Int16] {
    (0..<count).map { Int16(8_000 * sin(2 * .pi * 440 * Double($0) / Double(rate))) }
}

/// `count` samples in -3...3 from a fixed-seed LCG: a quiet room, never digital silence.
private func quietNoise(count: Int) -> [Int16] {
    var seed: UInt32 = 0x5117_E0F5
    return (0..<count).map { _ in
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Int16(Int(seed >> 16) % 7 - 3)
    }
}

/// What a file capture says it heard, over the whole take.
private func sound(of samples: [Int16], rate: Int = rate) async throws -> InputSound {
    let dir = try scratchDirectory()
    let wav = try writeWAV(samples, rate: rate, in: dir)
    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible),
                                           writingTo: dir.appending(path: "audio/take.caf"))
    _ = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.immediately)
    await recorder.settle()
    return take.sound
}

/// 48 kHz samples alternating +1 and -1: never zero, but all of it is above what 16 kHz
/// keeps, so the 16 kHz clip is all zeros. Only the raw frames show it is not a dead input.
private func inaudibleHiss(count: Int) -> [Int16] { (0..<count).map { $0.isMultiple(of: 2) ? 1 : -1 } }

/// A headless system whose local engine hears `engine`, as the other headless tests set one up.
private func headless(_ engine: ScriptedTranscriber) throws -> HeadlessSystem {
    try HeadlessSystem.make(paths: .temporary(), context: .unknown, preferences: .defaults, local: engine,
                            clock: TestClock())
}

/// The notices of one Dictation, read up to its end: `finished`, or the silent-mic notice, which a
/// silent Dictation ends on instead. `events()` was subscribed before the run, and its buffer holds
/// everything the run emitted, so nothing is waited for.
private func notices(_ events: AsyncStream<ConductorEvent>) async -> [Notice] {
    var found: [Notice] = []
    for await event in events {
        if case .notice(let notice) = event { found.append(notice) }
        if case .finished = event { break }
        if case .notice(.microphoneSilent) = event { break }
    }
    return found
}

// MARK: Capture

@Test(.timeLimit(.minutes(1))) func anAllZeroTakeSaysZeros() async throws {
    #expect(try await sound(of: zeroSamples(count: rate)) == .zeros)
}

@Test(.timeLimit(.minutes(1))) func aQuietButNonZeroTakeIsReal() async throws {
    #expect(try await sound(of: quietNoise(count: rate)) == .real)
}

@Test(.timeLimit(.minutes(1))) func aTakeThatIsZeroAtFirstAndThenSoundIsReal() async throws {
    #expect(try await sound(of: zeroSamples(count: rate / 2) + loudTone(count: rate / 2)) == .real)
}

@Test(.timeLimit(.minutes(1))) func aTakeJudgesTheRawFramesNotThe16kHzClip() async throws {
    #expect(try await sound(of: inaudibleHiss(count: 48_000), rate: 48_000) == .real)
}

// MARK: Headless Dictation

@Test(.timeLimit(.minutes(1)))
func anAllZeroDictationFailsAsASilentMicKeepsItsAudioAndIsNotTranscribed() async throws {
    let wav = try writeWAV(zeroSamples(count: rate), rate: rate, in: try scratchDirectory())
    let engine = ScriptedTranscriber(text: "Ship it")
    let system = try headless(engine)
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()
    await system.conductor.recorder.settle()

    #expect(result.status == .failed)
    #expect(await engine.heard.isEmpty)  // zeros are not speech: no clip is transcribed
    let row = try #require(await system.history.dictation(result.id))
    #expect(row.status == .failed)
    #expect(try await statusReason(system.history, result.id) == "microphone: zeros")
    let kept = try CAFFile.read(system.history.audioURL(for: result.id)).samples
    #expect(!kept.isEmpty)
    #expect(kept.allSatisfy { $0 == 0 })
    let heard = await notices(events)
    #expect(heard == [.microphoneSilent])
}

@Test(.timeLimit(.minutes(1)))
func aQuietButNonZeroDictationIsInsertedWithNoSilentNotice() async throws {
    let wav = try writeWAV(quietNoise(count: rate), rate: rate, in: try scratchDirectory())
    let system = try headless(ScriptedTranscriber(text: "Ship it"))
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .inserted)
    let heard = await notices(events)
    #expect(!heard.contains(.microphoneSilent))
}

@Test(.timeLimit(.minutes(1)))
func aMicThatComesBackAfterZerosIsInsertedWithNoSilentNotice() async throws {
    let source = zeroSamples(count: rate / 2) + loudTone(count: rate / 2)
    let wav = try writeWAV(source, rate: rate, in: try scratchDirectory())
    let system = try headless(ScriptedTranscriber(text: "Ship it"))
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)
    await system.history.flush()

    #expect(result.status == .inserted)  // the sound after the zeros was transcribed and typed
    let heard = await notices(events)
    #expect(!heard.contains(.microphoneSilent))
}

@Test(.timeLimit(.minutes(1)))
func anInputThatRoundsToZeroAt16kHzIsStillTranscribed() async throws {
    let wav = try writeWAV(inaudibleHiss(count: 48_000), rate: 48_000, in: try scratchDirectory())
    let system = try headless(ScriptedTranscriber(text: "Ship it"))
    let events = await system.conductor.events()

    let result = await system.conductor.dictate(file: wav, pace: .asFastAsPossible)

    #expect(result.status == .inserted)  // not a dead input, whatever the 16 kHz clip holds
    let heard = await notices(events)
    #expect(!heard.contains(.microphoneSilent))
}
