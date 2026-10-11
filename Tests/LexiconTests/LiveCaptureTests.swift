import AVFAudio
import CoreAudio
import Foundation
import Synchronization
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

// MARK: Device changes

@Test(.timeLimit(.minutes(1)))
func aSecondDeviceChangeRightAfterARebuildStillKeepsRecording() async throws {
    // The rebuilt engine stops itself again before it is watched, as a
    // Bluetooth switch that posts several changes can make it.
    let mic = FakeMic(diesAtStart: [1])
    let recorder = Recorder(hardware: mic.hardware)
    let capture = try await recorder.start(.microphone(deviceUID: nil),
                                           writingTo: try scratchDirectory().appending(path: "change.caf"))
    var engines = mic.made.makeAsyncIterator()
    var feed = capture.feed.makeAsyncIterator()

    var heard = 0
    while heard < FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    try #require(await engines.next()).hardwareChanged()
    // Only an engine built after the second change can bring the rest.
    while heard < 2 * FakeEngine.frames { heard += try #require(await feed.next()).samples.count }
    let take = await capture.stop(.immediately)
    await recorder.settle()

    #expect(take.clip.samples.count == 2 * FakeEngine.frames)
    #expect(take.summary.gaps.count == 1)
}

/// Mic hardware with no mic: every engine is a `FakeEngine` the test drives.
final class FakeMic: Sendable {
    let made: AsyncStream<FakeEngine>
    private let continuation: AsyncStream<FakeEngine>.Continuation
    private let count = Mutex(0)
    /// Engines, by the order they are made, that stop themselves the moment they start.
    private let diesAtStart: Set<Int>
    /// Starts, by the order they happen, that block their thread until `unwedge`.
    private let wedgesAtStart: Set<Int>
    /// Each engine whose start is blocked, as it blocks.
    let wedged: AsyncStream<FakeEngine>
    private let wedging: AsyncStream<FakeEngine>.Continuation
    private let starts = Mutex(0)
    private let gate = DispatchSemaphore(value: 0)
    private let unwedged = Atomic(false)
    private let clock: any Clock<Duration>
    /// macOS reports the permission undetermined, before and after the Allow prompt is answered.
    private let undetermined: Bool
    private let prompt = Mutex<(answered: Bool, asked: Int, waiting: [CheckedContinuation<Void, Never>])>(
        (false, 0, []))

    /// The default clock never moves: no start hits the limit because the machine is slow.
    init(diesAtStart: Set<Int> = [], wedgesAtStart: Set<Int> = [], clock: any Clock<Duration> = TestClock(),
         askingPermission: Bool = false) {
        (made, continuation) = AsyncStream.makeStream()
        (wedged, wedging) = AsyncStream.makeStream()
        self.diesAtStart = diesAtStart
        self.wedgesAtStart = wedgesAtStart
        self.clock = clock
        undetermined = askingPermission
    }

    var hardware: MicHardware {
        MicHardware(findDevice: { _ in 1 }, makeEngine: { [self] _ throws(RecorderError) in
            let index = count.withLock { count in
                defer { count += 1 }
                return count
            }
            let engine = FakeEngine(diesAtStart: diesAtStart.contains(index), wedge: { [self] engine in
                let index = starts.withLock { count in
                    defer { count += 1 }
                    return count
                }
                guard wedgesAtStart.contains(index) else { return nil }
                wedging.yield(engine)
                return gate
            })
            continuation.yield(engine)
            return engine
        }, permission: { [self] in undetermined ? .undetermined : .granted }, requestPermission: { [self] in
            await withCheckedContinuation { asked in
                let answered = prompt.withLock { prompt in
                    prompt.asked += 1
                    if !prompt.answered { prompt.waiting.append(asked) }
                    return prompt.answered
                }
                if answered { asked.resume() }
            }
            return true
        }, clock: clock)
    }

    /// How many times the Allow prompt was asked for.
    var timesAsked: Int { prompt.withLock { $0.asked } }

    /// Jake clicks Allow.
    func answerPrompt() {
        let waiting = prompt.withLock { prompt in
            prompt.answered = true
            defer { prompt.waiting = [] }
            return prompt.waiting
        }
        for asked in waiting { asked.resume() }
    }

    /// Lets every wedged start return, as a Core Audio call that was stuck finally does. Once.
    func unwedge() {
        guard !unwedged.exchange(true, ordering: .relaxed) else { return }
        for _ in wedgesAtStart { gate.signal() }
    }
}

/// An engine that, once started, has captured `frames` of a tone, and stops
/// itself on a hardware change as AVAudioEngine does.
final class FakeEngine: InputEngine, Sendable {
    static let frames = 1_600

    let device: AudioDeviceID = 1
    let segment = Segment(rate: Double(PCM16k.sampleRate))
    var changes: AnyObject { self }
    var isCurrent: Bool { false }
    var isRunning: Bool { running.load(ordering: .relaxed) }
    var firstAudio: HostTime? { stamp.withLock { $0 } }
    /// One element per `stop`, so a test can wait on it.
    let stopped: AsyncStream<Void>

    private let diesAtStart: Bool
    /// Asked at each start: a semaphore to block on, as a stuck Core Audio call does.
    private let wedge: @Sendable (FakeEngine) -> DispatchSemaphore?
    private let running = Atomic(false)
    private let stamp = Mutex<HostTime?>(nil)
    private let stops: AsyncStream<Void>.Continuation

    init(diesAtStart: Bool, wedge: @escaping @Sendable (FakeEngine) -> DispatchSemaphore? = { _ in nil }) {
        self.diesAtStart = diesAtStart
        self.wedge = wedge
        (stopped, stops) = AsyncStream.makeStream()
    }

    func start() throws(RecorderError) {
        wedge(self)?.wait()
        guard !diesAtStart else { return }
        running.store(true, ordering: .relaxed)
        let tone = (0..<Self.frames).map { Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) / 4 }
        _ = tone.withUnsafeBufferPointer { segment.ring.write($0) }
        stamp.withLock { $0 = .now() }
    }

    func stop() {
        running.store(false, ordering: .relaxed)
        stops.yield()
    }

    func hardwareChanged() {
        stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
}

extension MicHardware {
    /// No input device at all: every start throws.
    static var noMic: MicHardware {
        MicHardware(findDevice: { _ in nil }, makeEngine: { _ throws(RecorderError) in throw .noInputDevice },
                    permission: { .granted })
    }
}
