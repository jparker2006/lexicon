import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import AudioCapture
@testable import LexiconCore
import Cleanup
import History
import LexiconDomain
import LexiconUI
import Transcription
import WordStore

// #179: capture errors and dropped audio are reported, not swallowed. Each part
// below names its acceptance criterion.

// #179 criterion 1: a converter call that answers .error loses the input block it
// held, and the capture counts that audio as lost. File input: no mic, keys or network.

@Test(.timeLimit(.minutes(1))) func aConverterErrorDropsItsBlockAndCountsItAsLost() async throws {
    let dir = try scratchDirectory()
    // 2 s: the drain reads the file in many blocks, so the failed one sits between kept ones.
    let source = syntheticSamples(count: 32_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let fake = FailingConvert(pulls: true)

    let recorder = Recorder(policy: fake.policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible),
                                           writingTo: dir.appending(path: "audio/pulled.caf"))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    let seen = fake.trace
    let failed = try #require(seen.failed)
    // Block sizes come from the converter's own input buffers, never from the clip.
    let held = seen.blocks[failed]
    let before = seen.blocks[..<failed].reduce(0, +)
    #expect(seen.calls > 1)
    // Every sample before and after the failed block is kept, in order.
    #expect(take.clip.samples.prefix(before) == source.prefix(before))
    #expect(take.clip.samples.dropFirst(before) == source.dropFirst(before + held))
    #expect(framesAt16kHz(take.summary.lost) == held)
    #expect(take.clip.samples.count + held == source.count)
}

@Test(.timeLimit(.minutes(1))) func aConverterErrorThatNeverPulledItsBlockStillCountsItAsLost() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 32_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let fake = FailingConvert(pulls: false)

    // The failing call answers .error without taking its block, so the test cannot see
    // the block's size: only the summary says what was lost.
    let recorder = Recorder(policy: fake.policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible),
                                           writingTo: dir.appending(path: "audio/unpulled.caf"))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    let seen = fake.trace
    #expect(seen.calls > 1)
    #expect(take.summary.lost > .zero)
    #expect(take.clip.samples.count + framesAt16kHz(take.summary.lost) == source.count)
}

// MARK: Fixtures

/// The converter fake: its second call answers `.error` without calling the real
/// converter. Every other call is the real converter, and its input block is wrapped
/// only to count the frames of each block it is handed.
///
/// A class holding the Mutex, as the other fakes do: a Mutex parameter could not be
/// captured by the escaping closures the policy needs.
private final class FailingConvert: Sendable {
    /// What the fake saw: the calls made, each input block's frame count in the order
    /// the converter was handed them, and the index of the block the failing call held.
    struct Trace: Sendable {
        var calls = 0
        var blocks: [Int] = []
        var failed: Int?
    }

    private let state = Mutex(Trace())
    /// Whether the failing call takes its block first, as a converter that read the
    /// block and then failed does.
    private let pulls: Bool

    init(pulls: Bool) {
        self.pulls = pulls
    }

    var trace: Trace { state.withLock { $0 } }

    var policy: FlushPolicy {
        var policy = FlushPolicy()
        policy.convert = { [self] converter, output, input in
            self.convert(converter, output, input)
        }
        return policy
    }

    private func convert(_ converter: AVAudioConverter, _ output: AVAudioPCMBuffer,
                         _ input: @escaping AVAudioConverterInputBlock) -> (AVAudioConverterOutputStatus, NSError?) {
        let call = state.withLock { record -> Int in
            record.calls += 1
            return record.calls
        }
        let counting: AVAudioConverterInputBlock = { [self] packets, status in
            let block = input(packets, status)
            if let pcm = block as? AVAudioPCMBuffer {
                self.state.withLock { $0.blocks.append(Int(pcm.frameLength)) }
            }
            return block
        }
        guard call == 2 else { return Resampler.realConvert(converter, output, counting) }
        if pulls {
            var status = AVAudioConverterInputStatus.noDataNow
            let before = state.withLock { $0.blocks.count }
            _ = counting(output.frameCapacity, &status)
            state.withLock { record in
                if record.blocks.count > before { record.failed = before }
            }
        }
        return (.error, nil)
    }
}

/// A Duration as frames at 16 kHz, to the nearest frame. Compared in frames, not as an
/// exact Duration: the capture rounds the lost time to whole nanoseconds, and the held
/// count varies with timing, so an exact match would depend on which block failed.
private func framesAt16kHz(_ duration: Duration) -> Int {
    Int((duration / .seconds(1) * 16_000).rounded())
}

// #179, criteria 2 and 3: a file's failed sync or close is reported, not swallowed.
// Driven through the real Recorder on file input, with the FileCalls seam forced
// to fail. No mic, keys or network, and no clock: each test waits on a signal.

// MARK: Sync (criterion 2)

@Test(.timeLimit(.minutes(1)))
func aFailedFullSyncIsDiskTroubleAndTheTakeStaysInRAM() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/unsynced.caf")

    // Every tick syncs, so the first sync comes at once, and it fails.
    let (syncs, syncSignal) = AsyncStream<Void>.makeStream()
    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.sync = { _ in
        syncSignal.yield(())  // the test hears of the sync while the capture still runs
        return false  // F_FULLFSYNC and fsync both failed
    }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let problems = capture.signals.problems
    var firstSync = syncs.makeAsyncIterator()
    _ = await firstSync.next()
    // The stop queues behind the tick that made the sync, so the failure is handled before the take is finished.
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    var seen: [CaptureProblem] = []
    for await problem in problems { seen.append(problem) }  // the stream finishes at stop

    #expect(seen == [.diskTrouble])
    #expect(take.summary.storage == .ramOnly)
    #expect(take.clip.samples == source)
}

@Test(.timeLimit(.minutes(1)))
func aFullSyncThatWorksIsNoProblem() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/synced.caf")

    // A guard, not a red test: a sync that succeeds must not start the RAM fallback.
    let (syncs, syncSignal) = AsyncStream<Void>.makeStream()
    var policy = FlushPolicy()
    policy.fullSyncEvery = .zero
    policy.files.sync = { _ in
        syncSignal.yield(())
        return true
    }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let problems = capture.signals.problems
    var firstSync = syncs.makeAsyncIterator()
    _ = await firstSync.next()
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    var seen: [CaptureProblem] = []
    for await problem in problems { seen.append(problem) }

    #expect(seen.isEmpty)
    #expect(take.summary.storage == .onDisk)
    #expect(take.clip.samples == source)
}

// MARK: Close (criterion 3)

@Test(.timeLimit(.minutes(1)))
func aFileThatWillNotCloseIsRepairedWhenTheCaptureStops() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let caf = dir.appending(path: "audio/unclosed.caf")

    var policy = FlushPolicy()
    // AudioFileClose fails (-50, paramErr) and leaves the file open: its header keeps the data size at -1.
    policy.files.close = { _ in -50 }

    let recorder = Recorder(policy: policy)
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: caf)
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()  // returns once closeFile has run on the writer queue

    #expect(take.clip.samples == source)
    #expect(CAFFile.state(of: caf) == .closed)
    #expect(try CAFFile.read(caf).samples == take.clip.samples)
}

// #179 criterion 4: when the file cannot be written, the audio stays in RAM and
// the feed still yields every chunk. This is a guard, not a red test: it passes
// at the head because the feed is yielded whether or not the write succeeded.
// Synthesized input only, no mic, keys or network.

@Test func theFeedKeepsEveryChunkWhenTheFileCannotBeWritten() async throws {
    let dir = try scratchDirectory()
    let source = syntheticSamples(count: 16_000)
    let wav = try writeWAV(source, rate: 16_000, in: dir)
    let blocker = dir.appending(path: "audio")
    try Data().write(to: blocker)  // a plain file where the audio folder should be

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .asFastAsPossible), writingTo: blocker.appending(path: "x.caf"))
    let stream = capture.feed
    // Collecting starts before the input ends, so no chunk can be missed.
    let feed = Task { await collect(stream) }
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()
    let chunks = await feed.value

    // The fixture really is unwritable: the Dictation is RAM-only, so the feed is
    // the only other copy of what it heard.
    #expect(take.summary.storage == .ramOnly)
    #expect(take.clip.samples == source)
    #expect(chunks.flatMap(\.samples) == source)
    #expect(chunks.flatMap(\.samples) == take.clip.samples)
    #expect(chunks.map(\.index) == Array(chunks.indices))
}

// #179 criteria 5 and 6: audio the mic's ring refuses is counted as lost, and the
// Dictation says so. The overflow is `FakeMic(overflows:)`, an engine that writes
// more than its 2 s ring holds. No mic, keys or network.

// MARK: Ring overflow (criterion 5)

@Test(.timeLimit(.minutes(1)))
func aMicThatOutrunsItsRingReportsTheFramesItRefused() async throws {
    // The engine writes 2 s and 100 ms more: the ring keeps the first 2 s and refuses the rest.
    let mic = FakeMic(overflows: [0])
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "overflow.caf"))
    var feed = capture.feed.makeAsyncIterator()

    // Every kept frame is delivered before the stop, so the stop has nothing left to race.
    var heard = 0
    while heard < 2 * PCM16k.sampleRate { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()

    #expect(take.clip.samples.count == 2 * PCM16k.sampleRate)
    #expect(take.summary.lost == .milliseconds(100))  // 1_600 refused frames at 16 kHz
}

@Test(.timeLimit(.minutes(1)))
func aNormalMicCaptureReportsNoLoss() async throws {
    let mic = FakeMic()
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "normal.caf"))
    var feed = capture.feed.makeAsyncIterator()

    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()

    #expect(take.summary.lost == .zero)
}

// #179 criterion 7: a Dictation that lost audio says so on the pill, with the error sound.
// The line shows once the Dictation has stopped and clears when it lands. While Jake is still
// talking, the recording pill stays, as it does for every other notice.

private let dictation = DictationID()

/// Feeds the events in order and returns each step's state and sound.
private func follow(_ events: [ConductorEvent]) -> [(IndicatorState, SoundCue?)] {
    var follower = IndicatorFollower()
    return events.map { event in
        let cue = follower.apply(event)
        return (follower.state, cue)
    }
}

@Test func aLostAudioNoticeAfterTheStopShowsItsLineUntilTheDictationLands() {
    // Jake has let go of fn, so the notice shows its line and the error sound. Landing clears it.
    let events: [ConductorEvent] = [.confirmed(dictation, .hold), .stopped(dictation), .notice(.audioLost),
                                    .finished(dictation, .inserted)]
    let steps = follow(events)
    #expect(steps[2].0 == .error("Part of the audio was lost"))
    #expect(steps[2].1 == .error)
    #expect(steps[3].0 == .landed)
    #expect(steps.compactMap(\.1) == [.start, .stop, .error])
}

@Test func aLostAudioNoticeWhileRecordingLeavesThePillShowing() {
    // The error would hide itself after a moment with fn still down, so the recording stays and nothing sounds.
    let steps = follow([.confirmed(dictation, .hold), .notice(.audioLost)])
    #expect(steps.last?.0 == .recording(.hold, minuteLeft: false))
    #expect(steps.compactMap(\.1) == [.start])
}

// #179 criterion 8: a file whose read throws partway. The fixture is an AAC
// .m4a whose middle packets are zeroed on disk. AVAudioFile still opens it at
// its full length, and its read throws about 12800 frames in. The assertions
// count frames from the take, never compare samples: AAC is not bit exact.

private let fixtureFrames = 32_000  // 2 s at 16 kHz, the length AVAudioFile reports

/// An AAC .m4a of a 440 Hz tone, written by AVAudioFile. With `zeroedMiddle`,
/// the middle fifth of the packet bytes is zeroed after the writer closes.
private func makeAAC(at url: URL, zeroedMiddle: Bool) throws {
    let rate = 16_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
    do {  // the writer closes at the end of this block, so the bytes are whole before they are patched
        let writer = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fixtureFrames))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<fixtureFrames { buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 440 * Double(i) / rate)) }
        try writer.write(from: buffer)
    }
    guard zeroedMiddle else { return }
    var bytes = [UInt8](try Data(contentsOf: url))
    let tag = bytes.firstRange(of: Array("mdat".utf8))!.lowerBound
    let span = bytes[tag - 4..<tag].reduce(0) { $0 << 8 | Int($1) } - 8  // the mdat payload length
    let payload = tag + 4
    bytes.replaceSubrange(payload + span * 2 / 5..<payload + span * 3 / 5, with: [UInt8](repeating: 0, count: span / 5))
    try Data(bytes).write(to: url)
}

@Test(.timeLimit(.minutes(1))) func anAACFileThatBreaksOffMidFileKeepsWhatItReadAndCountsTheRest() async throws {
    let dir = try scratchDirectory()
    let m4a = dir.appending(path: "broken.m4a")
    try makeAAC(at: m4a, zeroedMiddle: true)
    let caf = dir.appending(path: "audio/broken.caf")  // audio/ does not exist yet

    let recorder = Recorder()
    let capture = try await recorder.start(.file(m4a, pace: .asFastAsPossible), writingTo: caf)
    // The read threw, so the input ends with no last sample. Waiting here is the signal, not a delay.
    #expect(await capture.signals.inputEnded() == nil)
    let take = await capture.stop(.immediately)
    await recorder.settle()

    #expect(!take.clip.samples.isEmpty)
    #expect(take.summary.lost > .zero)
    let lostFrames = Int((take.summary.lost / Duration.seconds(1) * 16_000).rounded())
    #expect(take.clip.samples.count + lostFrames == fixtureFrames)
}

@Test(.timeLimit(.minutes(1))) func anIntactAACFileReadsWholeWithNoLostAudio() async throws {
    let dir = try scratchDirectory()
    let m4a = dir.appending(path: "intact.m4a")
    try makeAAC(at: m4a, zeroedMiddle: false)

    let recorder = Recorder()
    let capture = try await recorder.start(.file(m4a, pace: .asFastAsPossible), writingTo: dir.appending(path: "audio/intact.caf"))
    let ended = try #require(await capture.signals.inputEnded())
    let take = await capture.stop(.released(at: ended))
    await recorder.settle()

    #expect(take.summary.lost == .zero)
}

@Test(.timeLimit(.minutes(1))) func stoppingEarlyReportsNoLostAudio() async throws {
    let dir = try scratchDirectory()
    let wav = try writeWAV(longSamples(), rate: 16_000, in: dir)

    let recorder = Recorder()
    let capture = try await recorder.start(.file(wav, pace: .realtime), writingTo: dir.appending(path: "audio/early.caf"))
    var feed = capture.feed.makeAsyncIterator()
    _ = try #require(await feed.next())  // one chunk in, and the file is nowhere near its end
    let take = await capture.stop(.immediately)
    while let chunk = await feed.next() { _ = chunk }
    await recorder.settle()

    // The read returns nil on a stop too, so a stop must not read as a broken file.
    #expect(take.summary.lost == .zero)
}

#if DEBUG
// MARK: The Dictation says so (criterion 6)

@Test(.timeLimit(.minutes(1)))
func aDictationThatLostAudioSaysSoAndLandsAndTheNextOneDoesNot() async throws {
    // Engine 0 overflows its ring; the next Dictation's engine, 1, is a normal mic.
    let rig = try HookRig(hardware: FakeMic(overflows: [0]).hardware)
    var events = await rig.conductor.events().makeAsyncIterator()

    let (lossy, lossyEvents) = try await holdOneFnPress(rig, &events)
    let (clean, cleanEvents) = try await holdOneFnPress(rig, &events)
    await rig.settle()

    #expect(lossyEvents.filter(\.isAudioLostNotice).count == 1)
    #expect(lossyEvents.contains { event in
        if case .finished(let who, .inserted) = event { who == lossy } else { false }
    })
    #expect(!cleanEvents.contains { $0.isAudioLostNotice })
    #expect(cleanEvents.contains { event in
        if case .finished(let who, .inserted) = event { who == clean } else { false }
    })
}

/// One fn press through the hooks, to its end: finished, or failed for a silent mic. Returns its
/// Dictation and every event from fn-down on, since the lost-audio notice comes after `.started`.
/// A copy of the helper in TestHooksMicTests, which is private there.
private func holdOneFnPress(_ rig: HookRig, _ events: inout AsyncStream<ConductorEvent>.Iterator) async throws
    -> (DictationID, [ConductorEvent])
{
    rig.keyboard.press(.fnDown(shift: false))
    let started = await rig.until(\.isStarted, in: &events)
    rig.keyboard.press(.fnUp(shift: false))
    let ended = await rig.until({ $0.isFinished || $0.isMicSilent }, in: &events)
    return (try #require(started.compactMap(\.startedID).first), started + ended)
}

private extension ConductorEvent {
    var isAudioLostNotice: Bool { if case .notice(.audioLost) = self { true } else { false } }
}

// MARK: The `audio drops` test hook (criterion 9 runs it live)

@Test(.timeLimit(.minutes(1)))
func theMicDropsHookLosesAudioOnceAndTheDictationIsStillTyped() async throws {
    let rig = try HookRig()
    var events = await rig.conductor.events().makeAsyncIterator()

    rig.recorder.dropNextCaptureBlock()
    let (lossy, lossyEvents) = try await holdOneFnPress(rig, &events)
    let (_, cleanEvents) = try await holdOneFnPress(rig, &events)
    await rig.settle()

    #expect(lossyEvents.filter(\.isAudioLostNotice).count == 1)
    #expect(lossyEvents.contains { $0.finishedStatus == .inserted })
    #expect(await rig.destination.delivered[lossy] != nil)
    #expect(!cleanEvents.contains { $0.isAudioLostNotice })
    #expect(cleanEvents.contains { $0.finishedStatus == .inserted })
}

@Test(.timeLimit(.minutes(1)))
func theAudioDropsHookWorksOnAFileDictationToo() async throws {
    // How Live checks runs criterion 9 hands-free: the hook, then a fixture dictated through the live path.
    let wav = try writeWAV(syntheticSamples(count: 19_200), rate: 16_000, in: try scratchDirectory())
    let paths = AppPaths.temporary()
    let recorder = Recorder()
    let conductor = Conductor(
        recorder: recorder, speech: SpeechEngine(local: ScriptedTranscriber(text: "Ship it"), clock: TestClock()),
        cleanup: Cleanup(), lexicon: try Lexicon(paths: paths), history: try HistoryStore(paths: paths),
        destination: HeadlessDestination(), preferences: PreferencesStore(fixed: .defaults),
        secrets: Secrets(.environment), keyboard: nil, fixes: nil, jev: nil)
    var events = await conductor.events().makeAsyncIterator()

    recorder.dropNextCaptureBlock()
    let result = await conductor.dictate(file: wav, pace: .asFastAsPossible)

    #expect(result.status == .inserted)
    var seen: [ConductorEvent] = []
    while let event = await events.next() {
        seen.append(event)
        if event.isFinished { break }
    }
    #expect(seen.filter(\.isAudioLostNotice).count == 1)
}
#endif
