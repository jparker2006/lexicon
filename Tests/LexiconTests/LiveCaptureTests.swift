import Foundation
import Testing
@testable import AudioCapture
import LexiconDomain

// Live mic capture (#52) without the mic: the adaptive tail as a pure seam, and
// the disk-full fallback through the same writer path the mic uses. The mic
// itself is checked in the live-app lane (`scripts/harness.sh hook capture`).

// MARK: The adaptive tail

@Test func aTailOverSpeechStopsAtTheCap() {
    var tail = Tail()
    #expect(tail.keep(tone(16_000)) == 16_000)  // before fn-up everything is kept
    tail.release(late: .zero)
    #expect(!tail.isOver)
    #expect(tail.keep(tone(8_000)) == 3_200)  // 200 ms, not a sample more
    #expect(tail.isOver)
    #expect(tail.keep(tone(160)) == 0)
}

@Test func aTailEndsAtFortyMillisecondsOfQuiet() {
    var tail = Tail()
    _ = tail.keep(tone(16_000))
    tail.release(late: .zero)
    #expect(tail.keep(tone(800) + silence(3_200)) == 800 + 640)  // the last word, then 40 ms of quiet
    #expect(tail.isOver)
}

@Test func quietAtFnUpNeedsNoTail() {
    var tail = Tail()
    _ = tail.keep(tone(16_000) + silence(640))
    tail.release(late: .zero)
    #expect(tail.isOver)
    #expect(tail.keep(tone(1_600)) == 0)
}

@Test func theCapCountsFromFnUpNotFromTheStopCall() {
    var tail = Tail()
    _ = tail.keep(tone(16_000))
    tail.release(late: .milliseconds(150))
    #expect(tail.keep(tone(8_000)) == 800)
    #expect(tail.isOver)
}

@Test func roomNoiseIsQuietAndSoftSpeechIsNot() {
    var hum = Tail()
    _ = hum.keep(tone(16_000))
    hum.release(late: .zero)
    #expect(hum.keep(tone(3_200, dBFS: -50)) == 640)

    var soft = Tail()
    _ = soft.keep(tone(16_000))
    soft.release(late: .zero)
    #expect(soft.keep(tone(8_000, dBFS: -40)) == 3_200)
}

@Test func howTheAudioIsChunkedDoesNotMoveTheEnd() {
    var tail = Tail()
    _ = tail.keep(tone(16_000))
    tail.release(late: .zero)
    let after = tone(800) + silence(3_200)
    var kept = 0
    for start in stride(from: 0, to: after.count, by: 37) {
        kept += tail.keep(Array(after[start..<min(start + 37, after.count)]))
    }
    #expect(kept == 800 + 640)
}

@Test func aStopLongAfterFnUpKeepsEverythingCapturedBeforeIt() async throws {
    // 48 kHz, so the converter still holds a few ms of audio when the stop comes.
    let source = (0..<48_000).map { Int16((sin(2 * Double.pi * 1_000 * Double($0) / 48_000) * 16_384).rounded()) }
    let wav = try writeWAV(source, rate: 48_000, in: try scratchDirectory())
    var counts: [Int] = []
    for late in [false, true] {
        let capture = try await Recorder().start(.file(wav, pace: .asFastAsPossible),
                                                 writingTo: try scratchDirectory().appending(path: "late.caf"))
        let ended = try #require(await capture.signals.inputEnded())
        // fn-up a whole second before the stop call: the 200 ms tail is long spent.
        let take = await capture.stop(late ? .released(at: HostTime(nanoseconds: ended.nanoseconds - 1_000_000_000))
                                           : .immediately)
        counts.append(take.clip.samples.count)
    }
    #expect(counts[1] == counts[0])
}

// MARK: Disk full

@Test func underTheFreeSpaceFloorTheAudioStaysInRAM() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/full.caf")

    let recorder = Recorder(policy: .diskFull)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let problems = capture.signals.problems
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    #expect(take.clip.samples == source)
    #expect(take.summary.storage == .ramOnly)
    #expect(await problems.first { _ in true } == .diskTrouble)
    #expect(!FileManager.default.fileExists(atPath: caf.path))  // nothing was started on a full disk
}

// MARK: Fixtures

extension FlushPolicy {
    /// No volume has this much free, so every capture starts in RAM only.
    static var diskFull: FlushPolicy {
        var policy = FlushPolicy()
        policy.minimumFreeBytes = .max
        return policy
    }
}

extension Tail {
    mutating func keep(_ samples: [Int16]) -> Int {
        samples.withUnsafeBufferPointer { keep($0) }
    }
}

/// A 440 Hz sine whose RMS is `dBFS`. The default is a speaking voice.
func tone(_ count: Int, dBFS: Double = -20) -> [Int16] {
    let peak = pow(10, dBFS / 20) * 32_768 * 2.0.squareRoot()
    return (0..<count).map { Int16((peak * sin(2 * .pi * 440 * Double($0) / 16_000)).rounded()) }
}

func silence(_ count: Int) -> [Int16] { Array(repeating: 0, count: count) }
