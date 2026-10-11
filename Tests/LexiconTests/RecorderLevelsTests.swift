import Foundation
import Testing
import AudioCapture

// The recording indicator's meter (#18): a level per captured chunk, for any
// number of observers. File input, so no mic.

@Test(.timeLimit(.minutes(1))) func observersHearTheLevelsOfAFileCapture() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: dir)
    let caf = dir.appending(path: "levels.caf")

    let recorder = Recorder()
    let levels = recorder.levels  // subscribed before the capture starts
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    // Waits for a chunk with sound in it: no sleep, so no machine speed in the test.
    let heard = try #require(await levels.first { $0.rms > 0 })
    #expect(heard.rms <= 1)  // full scale, as DictationIndicator.shown reads it
    let ended = try #require(await capture.signals.inputEnded())
    _ = await capture.stop(.released(at: ended))
    await recorder.settle()
}
