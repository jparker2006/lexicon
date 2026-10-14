import Foundation
import Testing
@testable import AudioCapture
import LexiconDomain

@Test func writerScheduleFirstAudioReachesDiskBeforeTimer() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(syntheticSamples(count: 16_000), rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/first.caf")
    let recorder = Recorder(policy: FlushPolicy(drainEvery: .seconds(60)))

    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: caf)
    _ = try #require(await capture.signals.inputEnded())
    let onDisk = (try? CAFFile.read(caf))?.samples.count ?? 0
    #expect(onDisk > 0)

    _ = await capture.stop(.immediately)
    await recorder.settle()
}
