import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import AudioCapture
import LexiconDomain

@Test(.timeLimit(.minutes(1)))
func converterFailureAfterHaveDataDoesNotCountAlreadyEmittedAudioAsLost() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 48_000)
    let wav = try writeWAV(source, rate: 48_000, in: dir)
    let fake = ContinuationFailure()

    let recorder = Recorder(policy: fake.policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible),
                                           writingTo: dir.appending(path: "audio/continued.caf"))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    let trace = fake.trace
    #expect(trace.failedAfterHaveData)
    #expect(!trace.outputBeforeFailure.isEmpty)
    #expect(Array(take.clip.samples.prefix(trace.outputBeforeFailure.count)) == trace.outputBeforeFailure)

    let lostFrames = Int((take.summary.lost / .seconds(1) * 16_000).rounded())
    let expectedFrames = source.count / 3
    #expect(abs(take.clip.samples.count + lostFrames - expectedFrames) <= 4)
}

/// Fails one continuation call after the real converter reports `.haveData`.
/// That response has already emitted samples, while the next call receives no
/// input and leaves the real converter's buffered state untouched.
private final class ContinuationFailure: Sendable {
    struct Trace: Sendable {
        var failedAfterHaveData = false
        var outputBeforeFailure: [Int16] = []
    }

    private struct State: Sendable {
        var trace = Trace()
        var emittedOutput: [Int16] = []
        var previousHadData = false
        var failed = false
    }

    private let state = Mutex(State())

    var trace: Trace { state.withLock { $0.trace } }

    var policy: FlushPolicy {
        var policy = FlushPolicy()
        policy.convert = { [self] converter, output, input in
            convert(converter, output, input)
        }
        return policy
    }

    private func convert(
        _ converter: AVAudioConverter,
        _ output: AVAudioPCMBuffer,
        _ input: @escaping AVAudioConverterInputBlock
    ) -> (AVAudioConverterOutputStatus, NSError?) {
        let shouldFail = state.withLock { current -> Bool in
            guard !current.failed, current.previousHadData else { return false }
            current.failed = true
            current.trace.failedAfterHaveData = true
            current.trace.outputBeforeFailure = current.emittedOutput
            return true
        }
        guard !shouldFail else { return (.error, nil) }

        let answer = Resampler.realConvert(converter, output, input)
        let produced = Int(output.frameLength)
        let samples: [Int16] = if produced > 0, let channel = output.int16ChannelData {
            Array(UnsafeBufferPointer(start: channel[0], count: produced))
        } else {
            []
        }
        state.withLock { current in
            current.previousHadData = answer.0 == .haveData
            current.emittedOutput.append(contentsOf: samples)
        }
        return answer
    }
}
